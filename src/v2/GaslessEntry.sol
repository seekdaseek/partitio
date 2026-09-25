// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IUSDG, IERC20Permit} from "./IUSDG.sol";
import {OracleGuard} from "./OracleGuard.sol";
import {PartitioRouterV2} from "./PartitioRouterV2.sol";

/// @title GaslessEntry
/// @notice One signature, no ETH. The user signs an order; a relayer pays gas and is repaid in
/// USDG out of the order, capped by the user's own `maxFeeUsdg` and by a hard percentage bound.
///
/// REPLAY PROTECTION. For a USDG order the EIP-3009 authorization nonce **is** the order hash, so
/// USDG's own `authorizationState` makes a second execution impossible at the token level. That is
/// belt; the `executed` mapping is braces, and it covers the stock-selling path where `permit`
/// carries no order binding at all. Both are enforced for every order rather than reasoning about
/// which path is protected by which.
///
/// ONE OUTPUT. Baskets are out of v1. The multi-output path could never be filled — one leg array
/// was reused for every output, so either the guard rejected the second output's zero fill or the
/// router silently bought the wrong token — and shipping an unreachable branch is worse than not
/// shipping it (review finding R-05).
///
/// THE AGGREGATOR LEG IS THE PRODUCT, not a bonus. Measured, partitio runs 1-87 bps behind Kyber
/// when Kyber answers, and Kyber answers roughly 47% of the time at our request rate. So the
/// relayer passes whichever route quoted highest, and this contract:
///   - only ever calls an aggregator target from an immutable allowlist fixed at deployment;
///   - approves exactly the amount, then resets the allowance to zero;
///   - accounts by balance delta bracketed around EACH external call, never by a return value and
///     never by subtracting from an assumed base;
///   - falls back to partitio IN THE SAME TRANSACTION if the aggregator leg reverts, under-delivers
///     or is beaten by partitio's own quote.
///
/// THE ORACLE FLOOR IS ONE AGGREGATE CHECK, run in `fill` after every branch, over the total input
/// measurably spent and the gross proceeds. It used to live inside the accepted-aggregator branch,
/// which meant a route that was *rejected* after eating most of the input was never guarded at all,
/// and `aggMinOut` — a relayer-supplied field — was an off-switch for it (review findings
/// `agg-reject-path-unguarded`, `aggminout-guard-offswitch`). There is now no branch that can skip
/// it.
contract GaslessEntry is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Order {
        address owner;
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minOut;        // floor on what the owner NETS, after any fee
        uint256 maxFeeUsdg;    // maximum the relayer may keep, ALWAYS in 6-decimal USDG
        uint256 deadline;
        bytes32 salt;
        OracleGuard.Params guard;
    }

    bytes32 private constant GUARD_TYPEHASH = keccak256("Guard(uint256 maxDevBps,uint256 maxFeedAge)");
    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address owner,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,uint256 maxFeeUsdg,uint256 deadline,bytes32 salt,Guard guard)Guard(uint256 maxDevBps,uint256 maxFeedAge)"
    );

    /// The absolute cap the user signs is a number; this is the shape. A relayer's real cost is
    /// gas, so a fee worth more than 0.50% of the order is not a fee, and an absolute cap alone
    /// could not express that — `maxFee` used to be documented as "in tokenIn units" while the fee
    /// was paid in USDG, which made the cap loose by ~10^12 on an 18-decimal sell (review finding
    /// `maxfee-denomination-sell`). The field is now named for its denomination and bounded twice.
    uint256 public constant MAX_FEE_BPS = 50; // 0.50%

    IUSDG public immutable USDG;
    PartitioRouterV2 public immutable ROUTER;
    address private immutable AGG0;
    address private immutable AGG1;
    address private immutable AGG2;
    address private immutable AGG3;

    mapping(bytes32 => bool) public executed;

    event OrderFilled(
        address indexed owner, bytes32 indexed orderHash, address indexed relayer,
        address tokenIn, address tokenOut, uint256 amountSpent, uint256 amountOut,
        uint256 feeUsdg, bool usedAggregator
    );
    event AggregatorLegRejected(address target, uint256 got, uint256 bar);

    error BadSignature();
    error AlreadyExecuted(bytes32 orderHash);
    error Expired();
    error SameToken();
    error FeeAboveMax(uint256 fee, uint256 limit);
    error OutputBelowMin(address token, uint256 got, uint256 minOut);
    error AggregatorNotAllowed(address target);
    error FeeNotPayableInUSDG();
    error LegsDoNotCoverOrder(uint256 sum, uint256 expected);
    error NothingSpent();
    error MinOutRequired();

    constructor(IUSDG usdg, PartitioRouterV2 router, address[4] memory aggregators)
        EIP712("partitio", "3")
    {
        USDG = usdg;
        ROUTER = router;
        AGG0 = aggregators[0];
        AGG1 = aggregators[1];
        AGG2 = aggregators[2];
        AGG3 = aggregators[3];
    }

    function isAllowedAggregator(address t) public view returns (bool) {
        return t != address(0) && (t == AGG0 || t == AGG1 || t == AGG2 || t == AGG3);
    }

    // ------------------------------------------------------------------ hashing

    function _hashGuard(OracleGuard.Params calldata g) internal pure returns (bytes32) {
        return keccak256(abi.encode(GUARD_TYPEHASH, g.maxDevBps, g.maxFeedAge));
    }

    function hashOrder(Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(
                ORDER_TYPEHASH, o.owner, o.tokenIn, o.amountIn, o.tokenOut, o.minOut,
                o.maxFeeUsdg, o.deadline, o.salt, _hashGuard(o.guard)
            ))
        );
    }

    // ------------------------------------------------------------------ entry

    struct Auth {
        uint8 v; bytes32 r; bytes32 s;          // the user's order signature
        uint8 pv; bytes32 pr; bytes32 ps;       // EIP-3009 / EIP-2612 signature
        uint256 validAfter; uint256 validBefore;
    }

    struct Route {
        address aggregator;      // address(0) = use partitio
        bytes callData;
        uint256 aggMinOut;       // what partitio would give for the same input, per the relayer
        PartitioRouterV2.Leg[] legs;   // partitio legs, also the fallback
    }

    /// @notice Fill a signed order. Caller (the relayer) pays gas and keeps `fee` in USDG.
    function fill(Order calldata o, Auth calldata a, Route calldata route, uint256 fee)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > o.deadline) revert Expired();
        if (o.tokenIn == o.tokenOut) revert SameToken();
        // A zero floor is the root of the sliver extraction the hunters found: every defence the
        // signer has left was the oracle band, which an honest price on a tiny amount clears. The
        // contract no longer accepts an order that declines to state what it expects to receive.
        if (o.minOut == 0) revert MinOutRequired();
        if (fee > o.maxFeeUsdg) revert FeeAboveMax(fee, o.maxFeeUsdg);

        bytes32 oh = hashOrder(o);
        if (executed[oh]) revert AlreadyExecuted(oh);
        executed[oh] = true;

        if (ECDSA.recover(oh, a.v, a.r, a.s) != o.owner) revert BadSignature();

        // THE FEE IS ALWAYS PAID IN USDG, never in stock.
        //   buy  (tokenIn == USDG): taken off the input, before the swap.
        //   sell (tokenIn != USDG): taken out of the USDG output, after the swap.
        // A route with no USDG on either side cannot pay a fee at all, and says so rather than
        // silently charging the user in whatever asset happened to be moving.
        bool feeFromInput = (o.tokenIn == address(USDG));
        if (fee != 0 && !feeFromInput && o.tokenOut != address(USDG)) revert FeeNotPayableInUSDG();

        uint256 inBefore = IERC20(o.tokenIn).balanceOf(address(this));
        _pullIn(o, a, oh);

        uint256 spendable = feeFromInput ? o.amountIn - fee : o.amountIn;

        // R-04: the relayer's legs must cover the whole order. Checked on the RAW legs, because
        // `_scaleLegs` rewrites them to sum to whatever it is handed — asserting the sum after
        // scaling would be a tautology, and asserting it on the aggregator remainder would break
        // the fallback outright.
        uint256 legSum;
        for (uint256 i = 0; i < route.legs.length; i++) legSum += route.legs[i].amountIn;
        if (legSum != spendable) revert LegsDoNotCoverOrder(legSum, spendable);

        uint256 spent;
        bool usedAgg;
        (amountOut, spent, usedAgg) = _fillSingle(o, route, spendable);
        if (spent == 0) revert NothingSpent();

        // ONE aggregate oracle floor, over gross proceeds against the input measurably spent.
        //
        // Gross, not net: on a buy the fee comes off the input so the guard's basis shrinks with
        // it, but on a sell the fee comes out of the output, and charging it against the band would
        // make small sells unfillable for arithmetic reasons rather than price ones — a $5 sell
        // with a $0.25 fee is 500 bps against the app's 200 bps default. The fee is separately
        // bounded by MAX_FEE_BPS and by the signed cap, and `minOut` below is checked on the NET.
        {
            (address feed, bool stockIsInput) = ROUTER.feedFor(o.tokenIn, o.tokenOut);
            OracleGuard.enforce(
                o.guard, feed, stockIsInput, spent, amountOut,
                IERC20Metadata(o.tokenIn).decimals(), IERC20Metadata(o.tokenOut).decimals()
            );
        }

        // THE FEE IS PRO RATA ON WHAT WAS ACTUALLY SPENT, and capped against the USDG side of the
        // trade that really happened — not against the size that was merely signed.
        //
        // The signed cap alone is not enough, and the percentage cap on `o.amountIn` was worse than
        // it looked. `fill` is permissionless, so any observer of a signed order is the relayer;
        // it could route a sliver at an honest price, clear the oracle floor (which is computed on
        // `spent`), and still collect the full signed fee. On a 1,000,000 USDG order with a
        // 5,000 USDG cap, routing 1,000 USDG is a 500% fee on the amount transacted while passing
        // a "0.50% of amountIn" check. Charging in proportion removes the incentive without
        // bricking a legitimate partial fill, which a hard minimum-fill rule would have done — and
        // a hard rule is also front-runnable: anyone can move a pool one wei to force a short fill.
        uint256 feeDue = spendable == 0 ? 0 : (fee * spent) / spendable;
        if (feeDue > fee) feeDue = fee;
        // The basis is the USDG that actually changed hands for this trade: on a buy that is what
        // was spent PLUS the fee itself, on a sell it is the gross proceeds (which are likewise net
        // plus fee). Using bare `spent` on a buy would be circular - the fee comes off the input,
        // so `spent` can never include it and a 0.50% cap would cap at 49.75% of itself.
        uint256 feeBasis = feeFromInput ? spent + feeDue : amountOut;
        if (feeDue * 10_000 > feeBasis * MAX_FEE_BPS) {
            revert FeeAboveMax(feeDue, (feeBasis * MAX_FEE_BPS) / 10_000);
        }
        if (feeDue != 0 && !feeFromInput) {
            if (feeDue > amountOut) revert FeeAboveMax(feeDue, amountOut);
            amountOut -= feeDue;
            IERC20(address(USDG)).safeTransfer(msg.sender, feeDue);
        }

        if (amountOut < o.minOut) revert OutputBelowMin(o.tokenOut, amountOut, o.minOut);
        IERC20(o.tokenOut).safeTransfer(o.owner, amountOut);

        if (feeDue != 0 && feeFromInput) IERC20(o.tokenIn).safeTransfer(msg.sender, feeDue);

        // Forward exactly THIS order's unspent input. Measured as a delta rather than as an
        // absolute balance: an absolute sweep would hand a previous order's residue — or an
        // attacker's donation — to whoever happens to sign next (review finding `r06-gasless-sweep`).
        // Must stay below the fee transfer, which also draws on tokenIn.
        uint256 inAfter = IERC20(o.tokenIn).balanceOf(address(this));
        if (inAfter > inBefore) IERC20(o.tokenIn).safeTransfer(o.owner, inAfter - inBefore);

        emit OrderFilled(o.owner, oh, msg.sender, o.tokenIn, o.tokenOut, spent, amountOut, feeDue, usedAgg);
    }

    // ------------------------------------------------------------------ internals

    function _pullIn(Order calldata o, Auth calldata a, bytes32 oh) internal {
        if (o.tokenIn == address(USDG)) {
            // The 3009 nonce IS the order hash: this authorization cannot fund any other order.
            USDG.receiveWithAuthorization(
                o.owner, address(this), o.amountIn, a.validAfter, a.validBefore, oh, a.pv, a.pr, a.ps
            );
            return;
        }
        // Stock side: permit if it helps, but a front-runner who submits the same permit first
        // must not be able to brick the order, so a failed permit is ignored when the allowance
        // already suffices.
        if (IERC20(o.tokenIn).allowance(o.owner, address(this)) < o.amountIn) {
            try IERC20Permit(o.tokenIn).permit(
                o.owner, address(this), o.amountIn, o.deadline, a.pv, a.pr, a.ps
            ) {} catch { /* allowance is re-checked by the transferFrom below */ }
        }
        IERC20(o.tokenIn).safeTransferFrom(o.owner, address(this), o.amountIn);
    }

    /// @notice Copy the caller's legs, rescaled so they sum to exactly `target`.
    /// @dev The legs are quoted for the full input. After a PARTIAL aggregator fill only the
    /// returned remainder is available, and handing the router the original amounts makes it pull
    /// more than the approval. Any rounding dust from the division is added to the last leg so the
    /// legs always sum to `target` exactly.
    function _scaleLegs(PartitioRouterV2.Leg[] calldata legs, uint256 target)
        internal pure returns (PartitioRouterV2.Leg[] memory out)
    {
        uint256 orig;
        for (uint256 i = 0; i < legs.length; i++) orig += legs[i].amountIn;
        out = new PartitioRouterV2.Leg[](legs.length);
        if (orig == 0 || legs.length == 0) return out;

        uint256 assigned;
        for (uint256 i = 0; i < legs.length; i++) {
            uint256 amt = i == legs.length - 1 ? target - assigned : (legs[i].amountIn * target) / orig;
            assigned += amt;
            out[i] = PartitioRouterV2.Leg({venue: legs[i].venue, proof: legs[i].proof, amountIn: amt});
        }
    }

    /// @return got gross proceeds of tokenOut, measured as a bracketed delta
    /// @return spent tokenIn measurably consumed by this call
    function _viaRouter(Order calldata o, PartitioRouterV2.Leg[] calldata legs, uint256 amountIn)
        internal
        returns (uint256 got, uint256 spent)
    {
        if (amountIn == 0) return (0, 0);
        PartitioRouterV2.Leg[] memory scaled = _scaleLegs(legs, amountIn);
        uint256 inBefore = IERC20(o.tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(o.tokenOut).balanceOf(address(this));
        IERC20(o.tokenIn).forceApprove(address(ROUTER), amountIn);
        ROUTER.swapExactIn(o.tokenIn, o.tokenOut, scaled, o.guard, 0, address(this), block.timestamp);
        IERC20(o.tokenIn).forceApprove(address(ROUTER), 0);
        got = IERC20(o.tokenOut).balanceOf(address(this)) - outBefore;
        uint256 inAfter = IERC20(o.tokenIn).balanceOf(address(this));
        spent = inAfter >= inBefore ? 0 : inBefore - inAfter;
    }

    function _fillSingle(Order calldata o, Route calldata route, uint256 spendable)
        internal
        returns (uint256 got, uint256 spent, bool usedAgg)
    {
        if (route.aggregator == address(0)) {
            (got, spent) = _viaRouter(o, route.legs, spendable);
            return (got, spent, false);
        }
        if (!isAllowedAggregator(route.aggregator)) revert AggregatorNotAllowed(route.aggregator);

        // Bracket the aggregator call on BOTH tokens. Deriving `spent` by subtracting a final
        // balance from an assumed base let a donated tokenIn deflate the oracle floor, because the
        // donation read as input the route had not consumed (review finding
        // `spent-must-be-bracketed-delta`).
        uint256 inBefore = IERC20(o.tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(o.tokenOut).balanceOf(address(this));
        IERC20(o.tokenIn).forceApprove(route.aggregator, spendable);
        (bool ok,) = route.aggregator.call(route.callData);
        IERC20(o.tokenIn).forceApprove(route.aggregator, 0);

        uint256 inAfter = IERC20(o.tokenIn).balanceOf(address(this));
        got = IERC20(o.tokenOut).balanceOf(address(this)) - outBefore;
        spent = inAfter >= inBefore ? 0 : inBefore - inAfter;

        if (ok && spent != 0 && spent <= spendable) {
            // The bar is NOT just the user's minOut — that floor is usually loose enough for a poor
            // aggregator fill to slip under it. It is `aggMinOut`: what partitio itself would
            // return for the same input, asserted by the relayer that quoted both. An aggregator
            // route is only worth taking if it beats our own route.
            //
            // A relayer that overstates aggMinOut forces the fallback, which used to be how the
            // oracle floor was switched off — the rejected branch guarded nothing. It no longer
            // buys anything: the aggregate floor in `fill` covers both branches, so this field is
            // now purely a routing preference.
            uint256 bar = o.minOut > route.aggMinOut ? o.minOut : route.aggMinOut;
            if (got >= bar) {
                usedAgg = true;
                // ACCEPTED - but accepting its PRICE is not the same as accepting its SIZE. The
                // remainder still falls through to the router below.
                //
                // Returning here was a hole. The relayer writes `route.callData`, so it chooses how
                // much the aggregator actually pulls, and `legSum == spendable` only bounds the
                // amount OFFERED. A route that consumed a thousandth of the order at an honest
                // price cleared the oracle floor (computed on `spent`) and the early return skipped
                // the fallback, so the signer was filled on 0.1% of their order and their order
                // hash was burned. Nothing else caught it: `minOut` would have, but nothing in this
                // repo signs a non-zero one.
            } else {
                emit AggregatorLegRejected(route.aggregator, got, bar);
            }
        }

        // Route whatever input is left, whether the aggregator's price was accepted or rejected.
        // `got` and `spent` accumulate across both legs, so the aggregate guard in `fill` sees the
        // whole trade either way.
        // `spendable - spent` is always actually held: this order pulled in `amountIn`, the
        // aggregator took `spent` of it, and `amountIn - spendable` is the fee reserve we must not
        // touch. Sizing from the budget rather than from `balanceOf` also means a donation cannot
        // be routed into the order, which would otherwise inflate the guard's basis.
        uint256 remaining = spendable > spent ? spendable - spent : 0;
        if (remaining > 0) {
            (uint256 got2, uint256 spent2) = _viaRouter(o, route.legs, remaining);
            got += got2;
            spent += spent2;
        }
        // `usedAgg`, not `false`. The named return was set on the accept branch above and then
        // thrown away here, so OrderFilled.usedAggregator was ALWAYS false - blinding off-chain
        // monitoring of precisely the branch that carried the sliver hole, on a contract that
        // cannot be patched. Harmless to funds, which is exactly why it would have survived.
        return (got, spent, usedAgg);
    }
}
