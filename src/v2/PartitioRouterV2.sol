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
/// NO OWNER. v1 had an owner-updatable venue registry; this does not. Venues are leaves of an
/// immutable Merkle tree fixed at deployment, and every leg carries its own proof. Nobody —
/// including the deployer — can add a venue, point a leg at a hostile contract, or pause the
/// router. Extending coverage means deploying a new router with a new root, which is a visible
/// act rather than a silent one.
///
/// Callback authentication is transient-storage identity, not CREATE2 derivation: `up-v3` pools on
/// this chain are EIP-1167 clones whose addresses are not a function of the pool key, so
/// derivation is unsound here. Before each external call the expected callee is written to a
/// transient slot; the callback requires `msg.sender` to equal it. EIP-1153 is confirmed working
/// on 4663 (ArbOS 116) — proven by `eth_call` state override against a storage control.
///
/// Maker legs are best effort. Rialto's published spec says propAMM settlement is router-only; it
/// is not enforced by the deployed code today, but that can change. A maker leg that reverts or
/// under-fills never bricks a route — the amount falls through to the AMM legs in the same call —
/// and the oracle floor is enforced across the whole route regardless.
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
    bytes32 private constant T_UNLOCKED = keccak256("partitio.v2.v4InFlight");
    bytes32 private constant T_ENTERED  = keccak256("partitio.v2.reentrancy");

    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    /// @notice Immutable Merkle root over `keccak256(abi.encode(Venue))` leaves.
    bytes32 public immutable VENUE_ROOT;
    IPoolManager public immutable poolManager;

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

    error Reentrancy();
    error Expired();
    error NothingRouted();
    error BadVenueProof(uint256 legIndex);
    error BadCallback();
    error InsufficientOutput(uint256 got, uint256 minOut);
    error TokenNotInVenue();

    modifier nonReentrant() {
        bytes32 s = T_ENTERED;
        assembly { if tload(s) { mstore(0x00, 0xab143c06) revert(0x1c, 0x04) } tstore(s, 1) }
        _;
        assembly { tstore(s, 0) }
    }

    constructor(IPoolManager _poolManager, bytes32 _venueRoot) {
        poolManager = _poolManager;
        VENUE_ROOT = _venueRoot;
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

    // ------------------------------------------------------------------ swap

    /// @notice Execute a caller-supplied split, in either direction, under an oracle floor.
    /// @param minOut the caller's own floor; the oracle floor is enforced on top of it, so the
    /// effective floor is the stricter of the two. Both must hold.
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
            if (_execute(legs[i].venue, tokenIn, legs[i].amountIn)) filled++;
            else { unfilled += legs[i].amountIn; emit LegFailed(legs[i].venue.target, legs[i].amountIn); }
        }
        // best-effort fallback: anything a venue declined goes to the first AMM leg that worked
        if (unfilled != 0) {
            for (uint256 i = 0; i < legs.length && unfilled != 0; i++) {
                if (legs[i].venue.kind == Kind.MAKER) continue;
                if (_execute(legs[i].venue, tokenIn, unfilled)) { unfilled = 0; filled++; }
            }
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        (uint256 floorOut, uint256 updatedAt) = OracleGuard.enforce(
            guard, total - unfilled, amountOut, IERC20Metadata(tokenIn).decimals(), IERC20Metadata(tokenOut).decimals()
        );

        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        if (unfilled != 0) IERC20(tokenIn).safeTransfer(msg.sender, unfilled);

        emit Routed(tokenIn, tokenOut, recipient, total - unfilled, amountOut, filled, floorOut, updatedAt);
    }

    // ------------------------------------------------------------------ legs

    function _execute(Venue memory v, address tokenIn, uint256 amountIn) internal returns (bool) {
        if (v.kind == Kind.V3) {
            if (tokenIn != v.token0 && tokenIn != v.token1) revert TokenNotInVenue();
            bool zeroForOne = (v.token0 == tokenIn);
            bytes32 s = T_EXPECTED;
            address t = v.target;
            assembly { tstore(s, t) }
            try IUniswapV3Pool(v.target).swap(
                address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT : MAX_SQRT, abi.encode(v.target)
            ) { assembly { tstore(s, 0) } return true; }
            catch { assembly { tstore(s, 0) } return false; }
        }
        if (v.kind == Kind.V4) {
            if (tokenIn != v.token0 && tokenIn != v.token1) revert TokenNotInVenue();
            bool zeroForOne = (v.token0 == tokenIn);
            PoolKey memory key =
                PoolKey(Currency.wrap(v.token0), Currency.wrap(v.token1), v.fee, v.tickSpacing, v.hooks);
            bytes32 s = T_UNLOCKED;
            assembly { tstore(s, 1) }
            try poolManager.unlock(abi.encode(key, zeroForOne, amountIn)) {
                assembly { tstore(s, 0) } return true;
            } catch { assembly { tstore(s, 0) } return false; }
        }
        // MAKER
        if (tokenIn != v.token0 && tokenIn != v.token1) revert TokenNotInVenue();
        bool zfo = (v.token0 == tokenIn);
        IERC20(tokenIn).forceApprove(v.target, amountIn);
        try IPropPair(v.target).swapExactIn(zfo, amountIn, 0, address(this), block.timestamp) returns (uint256 o) {
            IERC20(tokenIn).forceApprove(v.target, 0);
            return o != 0;
        } catch {
            IERC20(tokenIn).forceApprove(v.target, 0);
            return false;
        }
    }

    // ------------------------------------------------------------------ callbacks

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        bytes32 s = T_EXPECTED;
        address expected;
        assembly { expected := tload(s) }
        address pool = abi.decode(data, (address));
        if (msg.sender != expected || pool != expected) revert BadCallback();
        if (amount0Delta > 0) IERC20(IUniswapV3Pool(pool).token0()).safeTransfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(pool).token1()).safeTransfer(pool, uint256(amount1Delta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        bytes32 s = T_UNLOCKED;
        uint256 inFlight;
        assembly { inFlight := tload(s) }
        if (msg.sender != address(poolManager) || inFlight == 0) revert BadCallback();

        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        int256 delta = poolManager.swap(
            key, SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT : MAX_SQRT), ""
        );
        int128 owed = zeroForOne ? delta.amount0() : delta.amount1();
        int128 gained = zeroForOne ? delta.amount1() : delta.amount0();
        address tIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address tOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        poolManager.sync(Currency.wrap(tIn));
        IERC20(tIn).safeTransfer(address(poolManager), uint256(uint128(-owed)));
        poolManager.settle();
        poolManager.take(Currency.wrap(tOut), address(this), uint256(uint128(gained)));
        return abi.encode(uint256(uint128(gained)));
    }
}
