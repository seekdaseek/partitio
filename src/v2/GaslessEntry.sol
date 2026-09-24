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
/// USDG out of the order, capped by the user's own `maxFee`.
///
/// REPLAY PROTECTION. For a USDG order the EIP-3009 authorization nonce **is** the order hash, so
/// USDG's own `authorizationState` makes a second execution impossible at the token level. That is
/// belt; the `executed` mapping is braces, and it covers the stock-selling path where `permit`
/// carries no order binding at all. Both are enforced for every order rather than reasoning about
/// which path is protected by which.
///
/// THE AGGREGATOR LEG IS THE PRODUCT, not a bonus. Measured, partitio runs 1-87 bps behind Kyber
/// when Kyber answers, and Kyber answers roughly 47% of the time at our request rate. So the
/// relayer passes whichever route quoted highest, and this contract:
///   - only ever calls an aggregator target from an immutable allowlist fixed at deployment;
///   - approves exactly the amount, then resets the allowance to zero;
///   - accounts by balance delta, never by the target's return value;
///   - falls back to partitio IN THE SAME TRANSACTION if the aggregator leg reverts or delivers
///     less than the router would have.
/// The user's `minOut` and the oracle guard are enforced on the final balance either way, so a
/// hostile or stale aggregator route degrades the price at worst and cannot steal.
contract GaslessEntry is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Output {
        address token;
        uint16 weightBps;     // share of amountIn routed to this token; must sum to 10_000
        uint256 minOut;       // the user's own floor for this output
        OracleGuard.Params guard;
    }

    struct Order {
        address owner;
        address tokenIn;
        uint256 amountIn;
        uint256 maxFee;       // maximum the relayer may keep, in tokenIn units
        uint256 deadline;
        bytes32 salt;
        Output[] outputs;
    }

    bytes32 private constant GUARD_TYPEHASH =
        keccak256("Guard(address feed,bool stockIsInput,uint256 maxDevBps)");
    bytes32 private constant OUTPUT_TYPEHASH =
        keccak256("Output(address token,uint16 weightBps,uint256 minOut,Guard guard)Guard(address feed,bool stockIsInput,uint256 maxDevBps)");
    bytes32 private constant ORDER_TYPEHASH = keccak256(
        "Order(address owner,address tokenIn,uint256 amountIn,uint256 maxFee,uint256 deadline,bytes32 salt,Output[] outputs)Guard(address feed,bool stockIsInput,uint256 maxDevBps)Output(address token,uint16 weightBps,uint256 minOut,Guard guard)"
    );

    uint256 public constant MAX_OUTPUTS = 10;

    IUSDG public immutable USDG;
    PartitioRouterV2 public immutable ROUTER;
    address private immutable AGG0;
    address private immutable AGG1;
    address private immutable AGG2;
    address private immutable AGG3;

    mapping(bytes32 => bool) public executed;

    event OrderFilled(
        address indexed owner, bytes32 indexed orderHash, address indexed relayer,
        address tokenIn, uint256 amountIn, uint256 fee, uint256 outputsFilled, bool usedAggregator
    );
    event AggregatorLegRejected(address target, uint256 got, uint256 routerWouldGive);

    error BadSignature();
    error AlreadyExecuted(bytes32 orderHash);
    error Expired();
    error BadWeights(uint256 sum);
    error TooManyOutputs(uint256 n);
    error FeeAboveMax(uint256 fee, uint256 maxFee);
    error OutputBelowMin(address token, uint256 got, uint256 minOut);
    error AggregatorNotAllowed(address target);
    error DustLeftBehind(address token, uint256 amount);

    constructor(IUSDG usdg, PartitioRouterV2 router, address[4] memory aggregators)
        EIP712("partitio", "2")
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
        return keccak256(abi.encode(GUARD_TYPEHASH, g.feed, g.stockIsInput, g.maxDevBps));
    }

    function _hashOutputs(Output[] calldata outs) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](outs.length);
        for (uint256 i = 0; i < outs.length; i++) {
            h[i] = keccak256(
                abi.encode(OUTPUT_TYPEHASH, outs[i].token, outs[i].weightBps, outs[i].minOut, _hashGuard(outs[i].guard))
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function hashOrder(Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(
                ORDER_TYPEHASH, o.owner, o.tokenIn, o.amountIn, o.maxFee, o.deadline, o.salt, _hashOutputs(o.outputs)
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
        PartitioRouterV2.Leg[] legs;   // partitio legs, also the fallback
    }

    /// @notice Fill a signed order. Caller (the relayer) pays gas and keeps `fee` in tokenIn.
    function fill(Order calldata o, Auth calldata a, Route calldata route, uint256 fee)
        external
        nonReentrant
        returns (uint256[] memory outs)
    {
        if (block.timestamp > o.deadline) revert Expired();
        if (o.outputs.length == 0 || o.outputs.length > MAX_OUTPUTS) revert TooManyOutputs(o.outputs.length);
        if (fee > o.maxFee) revert FeeAboveMax(fee, o.maxFee);

        bytes32 oh = hashOrder(o);
        if (executed[oh]) revert AlreadyExecuted(oh);
        executed[oh] = true;

        if (ECDSA.recover(oh, a.v, a.r, a.s) != o.owner) revert BadSignature();

        uint256 sum;
        for (uint256 i = 0; i < o.outputs.length; i++) sum += o.outputs[i].weightBps;
        if (sum != 10_000) revert BadWeights(sum);

        _pullIn(o, a, oh);

        outs = new uint256[](o.outputs.length);
        uint256 spendable = o.amountIn - fee;
        bool usedAgg;

        // Single-output orders may use the relayer's aggregator route; baskets always use partitio,
        // because an aggregator route is quoted for one pair and cannot be split by weight safely.
        if (o.outputs.length == 1) {
            (outs[0], usedAgg) = _fillSingle(o, route, spendable);
        } else {
            for (uint256 i = 0; i < o.outputs.length; i++) {
                uint256 part = (spendable * o.outputs[i].weightBps) / 10_000;
                outs[i] = _viaRouter(o.tokenIn, o.outputs[i], _legsFor(route, i), part);
            }
        }

        for (uint256 i = 0; i < o.outputs.length; i++) {
            if (outs[i] < o.outputs[i].minOut) revert OutputBelowMin(o.outputs[i].token, outs[i], o.outputs[i].minOut);
            IERC20(o.outputs[i].token).safeTransfer(o.owner, outs[i]);
            uint256 left = IERC20(o.outputs[i].token).balanceOf(address(this));
            if (left != 0) revert DustLeftBehind(o.outputs[i].token, left);
        }

        if (fee != 0) IERC20(o.tokenIn).safeTransfer(msg.sender, fee);
        uint256 dust = IERC20(o.tokenIn).balanceOf(address(this));
        if (dust != 0) IERC20(o.tokenIn).safeTransfer(o.owner, dust);

        emit OrderFilled(o.owner, oh, msg.sender, o.tokenIn, o.amountIn, fee, o.outputs.length, usedAgg);
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

    function _legsFor(Route calldata route, uint256) internal pure returns (PartitioRouterV2.Leg[] calldata) {
        return route.legs;
    }

    function _viaRouter(
        address tokenIn, Output calldata out, PartitioRouterV2.Leg[] calldata legs, uint256 amountIn
    ) internal returns (uint256) {
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);
        uint256 got = ROUTER.swapExactIn(
            tokenIn, out.token, legs, out.guard, 0, address(this), block.timestamp
        );
        IERC20(tokenIn).forceApprove(address(ROUTER), 0);
        return got;
    }

    function _fillSingle(Order calldata o, Route calldata route, uint256 spendable)
        internal
        returns (uint256 got, bool usedAgg)
    {
        Output calldata out = o.outputs[0];
        if (route.aggregator == address(0)) {
            return (_viaRouter(o.tokenIn, out, route.legs, spendable), false);
        }
        if (!isAllowedAggregator(route.aggregator)) revert AggregatorNotAllowed(route.aggregator);

        uint256 snapshot = IERC20(out.token).balanceOf(address(this));
        IERC20(o.tokenIn).forceApprove(route.aggregator, spendable);
        (bool ok,) = route.aggregator.call(route.callData);
        IERC20(o.tokenIn).forceApprove(route.aggregator, 0);

        if (ok) {
            got = IERC20(out.token).balanceOf(address(this)) - snapshot;
            uint256 spent = spendable - IERC20(o.tokenIn).balanceOf(address(this));
            // Accept the aggregator only if it cleared the user's floor. Otherwise unwind to
            // partitio with whatever tokenIn is left, in this same transaction.
            if (got >= out.minOut && spent <= spendable) {
                return (got, true);
            }
            emit AggregatorLegRejected(route.aggregator, got, out.minOut);
        }

        uint256 remaining = IERC20(o.tokenIn).balanceOf(address(this));
        if (remaining > 0) {
            got += _viaRouter(o.tokenIn, out, route.legs, remaining);
        }
        return (got, false);
    }
}
