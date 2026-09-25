// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OracleGuard} from "./OracleGuard.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "../interfaces/IUniswapV3Pool.sol";
import {IPropPair} from "../interfaces/IPropPair.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, Currency, BalanceDeltaLib} from "../interfaces/IPoolManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title PartitioRouterV2
/// @notice Splits an order across Robinhood Chain's on-chain venues, in either direction, and
/// settles atomically under a Chainlink-referenced floor.
///
/// THE SPLIT IS NOT COMPUTED HERE. It arrives in `legs`, computed off-chain by partitio's quoter.
/// What is on-chain is the *enforcement*: immutable venue proofs, the caller's `minOut`, the oracle
/// floor, and — since the independent review — measured settlement. Do not describe this contract
/// as splitting on-chain; see docs/HEADLINE.md rule 5.
///
/// NO OWNER. v1 had an owner-updatable venue registry; this does not. Venues are leaves of an
/// immutable Merkle tree fixed at deployment, every leg carries its own proof, and the token->feed
/// map is fixed in the constructor. Nobody — including the deployer — can add a venue, repoint a
/// feed, aim a leg at a hostile contract, or pause the router. Extending coverage means deploying a
/// new router, which is a visible act rather than a silent one.
///
/// Callback authentication is transient-storage identity, not CREATE2 derivation: `up-v3` pools on
/// this chain are EIP-1167 clones whose addresses are not a function of the pool key, so derivation
/// is unsound here. Before each external call the expected callee, the token we may pay, and the
/// amount we may pay are written to transient slots; the callback trusts only those. EIP-1153 is
/// confirmed working on 4663 (ArbOS 116) — proven by `eth_call` state override against a storage
/// control.
///
/// Maker legs are best effort. Rialto's published spec says propAMM settlement is router-only; it
/// is not enforced by the deployed code today, but that can change. A leg that reverts, declines or
/// SHORT-FILLS never bricks a route — whatever it did not consume falls through to the other legs
/// in the same call and is refunded if nothing takes it — and the oracle floor is enforced across
/// the whole route on the amount genuinely spent.
contract PartitioRouterV2 is IUniswapV3SwapCallback, IUnlockCallback {
    using BalanceDeltaLib for int256;
    using SafeERC20 for IERC20;

    enum Kind { V3, V4, MAKER }

    struct Venue {
        Kind kind;
        address target;      // v3/up-v3 pool, or maker pair; unused for v4
        address token0;
        address token1;
        uint24 fee;          // v4 pool key
        int24 tickSpacing;   // v4 pool key
        address hooks;       // v4 pool key
    }

    struct Leg {
        Venue venue;
        bytes32[] proof;
        uint256 amountIn;
    }

    bytes32 private constant T_EXPECTED = keccak256("partitio.v2.expectedCallee");
    bytes32 private constant T_PAYTOKEN = keccak256("partitio.v2.payToken");
    bytes32 private constant T_BUDGET   = keccak256("partitio.v2.legBudget");
    bytes32 private constant T_UNLOCKED = keccak256("partitio.v2.v4Payload");
    bytes32 private constant T_ENTERED  = keccak256("partitio.v2.reentrancy");

    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    /// @notice Immutable Merkle root over `keccak256(abi.encode(Venue))` leaves.
    bytes32 public immutable VENUE_ROOT;
    IPoolManager public immutable poolManager;

    /// @notice Immutable stock token -> Chainlink aggregator. Fixed in the constructor, no setter.
    ///
    /// A MAP RATHER THAN A SECOND MERKLE ROOT, deliberately. The property needed is ONE feed per
    /// token, and a mapping enforces that structurally — a duplicate key is rejected at deploy. A
    /// Merkle multiset cannot: leaves (AAPL, feedA) and (AAPL, feedB) both verify, and whoever
    /// supplies the proof picks. That is not hypothetical on 4663 — six tickers (AAPL, GOOGL, NVDA,
    /// QQQ, SPY, TSLA) have a second live aggregator, and the recon table that chose between them
    /// did so by "first Morpho market per ticker wins", which already miswired CRWV once. A map is
    /// also checkable: `feedOf(AAPL)` is one eth_call, where a root is only checkable by re-running
    /// the deployer's own script — precisely the trust an ownerless contract exists to avoid.
    mapping(address => address) public feedOf;

    event Routed(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint256 legsFilled,
        uint256 oracleFloor,
        uint256 feeUpdatedAt
    );
    event LegFailed(address target, uint256 amountIn);
    event InputRefunded(address indexed payer, uint256 amount);

    error Reentrancy();
    error Expired();
    error NothingRouted();
    error BadVenueProof(uint256 legIndex);
    error BadCallback();
    error InsufficientOutput(uint256 got, uint256 minOut);
    error TokenNotInVenue();
    error SameToken();
    error LegOverdraw(address target, uint256 budget, uint256 asked);
    error NoFeedForPair(address tokenIn, address tokenOut);
    error AmbiguousPair(address tokenIn, address tokenOut);
    error FeedMapBad();

    modifier nonReentrant() {
        bytes32 s = T_ENTERED;
        assembly { if tload(s) { mstore(0x00, 0xab143c06) revert(0x1c, 0x04) } tstore(s, 1) }
        _;
        assembly { tstore(s, 0) }
    }

    constructor(
        IPoolManager _poolManager,
        bytes32 _venueRoot,
        address[] memory stockTokens,
        address[] memory feeds
    ) {
        poolManager = _poolManager;
        VENUE_ROOT = _venueRoot;
        if (stockTokens.length != feeds.length || stockTokens.length == 0) revert FeedMapBad();
        for (uint256 i = 0; i < stockTokens.length; i++) {
            if (stockTokens[i] == address(0) || feeds[i] == address(0)) revert FeedMapBad();
            if (feedOf[stockTokens[i]] != address(0)) revert FeedMapBad(); // duplicate token key
            // A duplicate FEED across two different tokens is the exact miswiring that already
            // happened on this chain once: the recon table picked "first Morpho market per ticker",
            // which pointed CRWV at CRCL's aggregator. Deploy-time only, and the immutables are
            // forever, so it is worth the loop.
            for (uint256 j = 0; j < i; j++) {
                if (feeds[j] == feeds[i]) revert FeedMapBad();
            }
            feedOf[stockTokens[i]] = feeds[i];
        }
    }

    // ------------------------------------------------------------------ views

    function venueLeaf(Venue calldata v) external pure returns (bytes32) {
        return _leaf(v);
    }

    function _leaf(Venue memory v) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(v))));
    }

    /// @dev sorted-pair Merkle verification, OpenZeppelin-compatible
    function _verify(bytes32[] memory proof, bytes32 leaf) internal view returns (bool) {
        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            h = h <= p ? keccak256(abi.encode(h, p)) : keccak256(abi.encode(p, h));
        }
        return h == VENUE_ROOT;
    }

    /// @notice Which side of this pair is the mapped stock, and what prices it.
    /// @dev The caller chooses neither. Exactly one side must be a mapped stock token: a pair with
    /// no mapped side has no reference price, and a stock/stock pair has two, so the guard's
    /// direction would be a coin flip. Both are refused rather than guessed.
    function feedFor(address tokenIn, address tokenOut)
        public
        view
        returns (address feed, bool stockIsInput)
    {
        address fIn = feedOf[tokenIn];
        address fOut = feedOf[tokenOut];
        if (fIn != address(0) && fOut != address(0)) revert AmbiguousPair(tokenIn, tokenOut);
        if (fIn != address(0)) return (fIn, true);
        if (fOut != address(0)) return (fOut, false);
        revert NoFeedForPair(tokenIn, tokenOut);
    }

    // ------------------------------------------------------------------ swap

    /// @notice Execute a caller-supplied split, in either direction, under an oracle floor.
    /// @param minOut the caller's own floor; the oracle floor is enforced on top of it, so the
    /// effective floor is the stricter of the two. Both must hold.
    /// @dev Whatever the venues do not consume is refunded to `msg.sender`, and the oracle floor is
    /// evaluated against the amount genuinely spent — not against the amount the caller asked to
    /// spend. Before the review these were the same number only because a short fill was invisible.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        Leg[] memory legs,
        OracleGuard.Params calldata guard,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (tokenIn == tokenOut) revert SameToken();
        (address feed, bool stockIsInput) = feedFor(tokenIn, tokenOut);

        uint256 total;
        for (uint256 i = 0; i < legs.length; i++) {
            if (!_verify(legs[i].proof, _leaf(legs[i].venue))) revert BadVenueProof(i);
            total += legs[i].amountIn;
        }
        if (total == 0) revert NothingRouted();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), total);
        uint256 before = IERC20(tokenOut).balanceOf(address(this));

        uint256 filled;
        uint256 unfilled;
        for (uint256 i = 0; i < legs.length; i++) {
            uint256 used = _execute(legs[i].venue, tokenIn, tokenOut, legs[i].amountIn);
            if (used == 0) emit LegFailed(legs[i].venue.target, legs[i].amountIn);
            else filled++;
            unfilled += legs[i].amountIn - used;
        }
        // Best-effort fallback: anything a venue declined or short-filled is offered to the AMM
        // legs, which may themselves take only part of it. Keep going while there is something left
        // and a leg still willing to take it.
        if (unfilled != 0) {
            for (uint256 i = 0; i < legs.length && unfilled != 0; i++) {
                if (legs[i].venue.kind == Kind.MAKER) continue;
                uint256 used = _execute(legs[i].venue, tokenIn, tokenOut, unfilled);
                if (used != 0) {
                    unfilled -= used;
                    filled++;
                }
            }
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        uint256 spent = total - unfilled;
        if (spent == 0) revert NothingRouted();

        (uint256 floorOut, uint256 updatedAt) = OracleGuard.enforce(
            guard, feed, stockIsInput, spent, amountOut,
            IERC20Metadata(tokenIn).decimals(), IERC20Metadata(tokenOut).decimals()
        );

        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        if (unfilled != 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, unfilled);
            emit InputRefunded(msg.sender, unfilled);
        }

        emit Routed(tokenIn, tokenOut, recipient, spent, amountOut, filled, floorOut, updatedAt);
    }

    // ------------------------------------------------------------------ legs

    /// @notice Run one leg and report how much `tokenIn` it actually consumed.
    /// @dev Returns MEASURED consumption, not a boolean. A v3 pool that exhausts its liquidity
    /// against the price limit, and a propAMM pair that part-fills, both return normally having
    /// taken less than they were offered; the old `return true` booked those as full fills and
    /// stranded the residue permanently in a contract with no sweep (review finding R-06).
    function _execute(Venue memory v, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 used)
    {
        if (amountIn == 0) return 0;
        if (tokenIn != v.token0 && tokenIn != v.token1) revert TokenNotInVenue();
        bool zeroForOne = (v.token0 == tokenIn);
        // The committed pair must be exactly {tokenIn, tokenOut}. Without this a leg could point at
        // a correctly-committed pool for a DIFFERENT quote asset: it would pass the proof and the
        // tokenIn check, spend real input, and deposit a third token that the output balance delta
        // never counts and nothing can ever recover (review finding `router-tokenout-unchecked`).
        if ((zeroForOne ? v.token1 : v.token0) != tokenOut) revert TokenNotInVenue();

        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));

        if (v.kind == Kind.V3) {
            bytes32 se = T_EXPECTED;
            bytes32 sp = T_PAYTOKEN;
            bytes32 sb = T_BUDGET;
            address t = v.target;
            uint256 budget = amountIn;
            assembly {
                tstore(se, t)
                tstore(sp, tokenIn)
                tstore(sb, budget)
            }
            try IUniswapV3Pool(t).swap(
                address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT : MAX_SQRT, abi.encode(t)
            ) {} catch {}
            assembly {
                tstore(se, 0)
                tstore(sp, 0)
                tstore(sb, 0)
            }
        } else if (v.kind == Kind.V4) {
            PoolKey memory key =
                PoolKey(Currency.wrap(v.token0), Currency.wrap(v.token1), v.fee, v.tickSpacing, v.hooks);
            bytes memory payload = abi.encode(key, zeroForOne, amountIn);
            bytes32 su = T_UNLOCKED;
            bytes32 h = keccak256(payload);
            assembly { tstore(su, h) }
            try poolManager.unlock(payload) {} catch {}
            assembly { tstore(su, 0) }
        } else {
            IERC20(tokenIn).forceApprove(v.target, amountIn);
            try IPropPair(v.target).swapExactIn(zeroForOne, amountIn, 0, address(this), block.timestamp) {}
            catch {}
            IERC20(tokenIn).forceApprove(v.target, 0);
        }

        uint256 balAfter = IERC20(tokenIn).balanceOf(address(this));
        if (balAfter >= balBefore) return 0; // consumed nothing, or handed tokenIn back
        used = balBefore - balAfter;
        if (used > amountIn) revert LegOverdraw(v.target, amountIn, used);
    }

    // ------------------------------------------------------------------ callbacks

    /// @dev `data` in a v3 callback is whatever the POOL passes, not something it is obliged to
    /// echo. R-07 and R-08 defend against a *committed* pool misbehaving, so the token we pay and
    /// the amount we may pay MUST come from transient slots we wrote ourselves — a version that
    /// read them out of `data` would let the one actor it defends against forge both, and would
    /// still pass every mock that echoes faithfully.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        bytes32 se = T_EXPECTED;
        bytes32 sp = T_PAYTOKEN;
        bytes32 sb = T_BUDGET;
        address expected;
        address payToken;
        uint256 budget;
        assembly {
            expected := tload(se)
            payToken := tload(sp)
            budget := tload(sb)
        }
        if (msg.sender != expected || payToken == address(0)) revert BadCallback();

        int256 owedSigned = amount0Delta > 0 ? amount0Delta : amount1Delta;
        if (owedSigned <= 0) return;
        uint256 owed = uint256(owedSigned);

        // The budget DECREMENTS, because nothing stops a pool calling back more than once inside a
        // single swap; a per-callback comparison would let it draw the full leg on each entry.
        if (owed > budget) revert LegOverdraw(expected, budget, owed);
        assembly { tstore(sb, sub(budget, owed)) }

        IERC20(payToken).safeTransfer(expected, owed);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        bytes32 su = T_UNLOCKED;
        bytes32 expectedHash;
        assembly { expectedHash := tload(su) }
        // Bind the payload, not just an in-flight flag: the PoolManager is trusted to echo, but
        // binding costs one keccak and removes the flag's "any unlock while we happen to be in
        // flight" shape.
        if (msg.sender != address(poolManager) || expectedHash == bytes32(0)) revert BadCallback();
        if (keccak256(data) != expectedHash) revert BadCallback();
        // Consume the binding on ENTRY, so one `unlock` can settle exactly once. The v3 callback
        // decrements its budget for precisely this reason - "nothing stops a pool calling back more
        // than once inside a single swap" - and stating that threat model there while leaving this
        // path re-entrant would be an asymmetry, not a decision.
        assembly { tstore(su, 0) }

        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        int256 delta = poolManager.swap(
            key, SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT : MAX_SQRT), ""
        );
        int128 owed = zeroForOne ? delta.amount0() : delta.amount1();
        int128 gained = zeroForOne ? delta.amount1() : delta.amount0();
        address tIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address tOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        uint256 owedAbs = uint256(uint128(-owed));
        // Same per-leg bound as the v3 path. A hook is part of the committed pool key, so it is a
        // registered actor, and registered actors are exactly what R-08 bounds.
        if (owedAbs > amountIn) revert LegOverdraw(address(poolManager), amountIn, owedAbs);

        poolManager.sync(Currency.wrap(tIn));
        IERC20(tIn).safeTransfer(address(poolManager), owedAbs);
        poolManager.settle();
        poolManager.take(Currency.wrap(tOut), address(this), uint256(uint128(gained)));
        return abi.encode(uint256(uint128(gained)));
    }
}
