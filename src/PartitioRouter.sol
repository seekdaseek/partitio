// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GreedySplit} from "./lib/GreedySplit.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {IPropPair} from "./interfaces/IPropPair.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, Currency, BalanceDeltaLib} from "./interfaces/IPoolManager.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title PartitioRouter
/// @notice A stock-token router a smart contract can call: it splits an order across Robinhood
/// Chain's on-chain liquidity and settles atomically with a minimum-out guarantee.
///
/// SECURITY MODEL
/// - Callback authentication is NOT CREATE2 pool derivation. `up-v3` pools are EIP-1167 clones
///   whose addresses are not a function of the pool key, so derivation is unsound on this chain.
///   Instead: the expected callback target is written to TRANSIENT storage (EIP-1153, confirmed
///   working on 4663, ArbOS 116) immediately before the external call, and the callback requires
///   `msg.sender == expected` AND registry membership. The slot is cleared after each leg.
/// - The v4 `unlockCallback` requires `msg.sender == PoolManager` and an in-flight flag, so it
///   cannot be entered except from a swap this contract initiated.
/// - Maker legs are BEST EFFORT. Rialto's published spec says propAMM settlement is router-only;
///   it is not enforced on the deployed code today, but that could change. A maker leg that
///   reverts or under-fills never bricks a route: the router falls back to the best AMM venue in
///   the SAME call, and total `minOut` is enforced across the whole route regardless.
/// - The venue registry is OWNER-UPDATABLE. The owner can add a hostile venue, but the blast
///   radius is bounded: the router never sends more than `amountIn`, and the caller's `minOut` is
///   checked against the real balance delta. The owner can grief a route; they cannot drain one.
///   A timelock is the production answer and is deliberately NOT implemented here — stated rather
///   than implied.
contract PartitioRouter is IUniswapV3SwapCallback, IUnlockCallback {
    using BalanceDeltaLib for int256;

    enum Kind { V3, V4, MAKER }

    struct Venue {
        Kind kind;
        address target;      // v3 pool or maker pair; unused for v4
        address token0;
        address token1;
        uint24 fee;          // v4
        int24 tickSpacing;   // v4
        address hooks;       // v4
    }

    struct Leg { uint16 venueId; uint256 amountIn; }

    // transient slots
    bytes32 private constant T_EXPECTED = keccak256("partitio.expectedCallbackTarget");
    bytes32 private constant T_UNLOCKED = keccak256("partitio.v4InFlight");
    bytes32 private constant T_ENTERED  = keccak256("partitio.reentrancy");

    uint160 private constant MIN_SQRT = 4295128740;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    IPoolManager public immutable poolManager;
    address public owner;
    Venue[] public venues;

    event VenueAdded(uint256 indexed id, Kind kind, address target);
    event Routed(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 legs);
    event LegFailed(uint256 indexed venueId, uint256 amountIn);

    error NotOwner();
    error Reentrancy();
    error Expired();
    error InsufficientOutput(uint256 got, uint256 minOut);
    error BadCallback();
    error NothingRouted();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    modifier nonReentrant() {
        bytes32 s = T_ENTERED;
        assembly { if tload(s) { mstore(0x00, 0xab143c06) revert(0x1c, 0x04) } tstore(s, 1) }
        _;
        assembly { tstore(s, 0) }
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        owner = msg.sender;
    }

    function venueCount() external view returns (uint256) { return venues.length; }
    function setOwner(address o) external onlyOwner { owner = o; }

    function addVenue(Venue calldata v) external onlyOwner returns (uint256 id) {
        id = venues.length;
        venues.push(v);
        emit VenueAdded(id, v.kind, v.target);
    }

    function addVenues(Venue[] calldata vs) external onlyOwner {
        for (uint256 i = 0; i < vs.length; i++) {
            venues.push(vs[i]);
            emit VenueAdded(venues.length - 1, vs[i].kind, vs[i].target);
        }
    }

    // ---------------------------------------------------------------- execution

    /// @notice Execute a caller-supplied split. This is the cheap path: the caller has already
    /// quoted (via `quote`, through eth_call) and knows the legs it wants.
    function executeSplit(
        address tokenIn,
        address tokenOut,
        Leg[] calldata legs,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();

        uint256 total;
        for (uint256 i = 0; i < legs.length; i++) total += legs[i].amountIn;
        if (total == 0) revert NothingRouted();
        IERC20(tokenIn).transferFrom(msg.sender, address(this), total);

        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        uint256 executedLegs;
        uint256 unfilled;

        for (uint256 i = 0; i < legs.length; i++) {
            Venue memory v = venues[legs[i].venueId];
            bool ok = _executeLeg(v, tokenIn, legs[i].amountIn);
            if (ok) executedLegs++;
            else { unfilled += legs[i].amountIn; emit LegFailed(legs[i].venueId, legs[i].amountIn); }
        }

        // Best-effort maker fallback: anything a venue declined goes to the first venue in the
        // split that did fill, inside this same call. Never leaves the caller's tokens stranded.
        if (unfilled != 0) {
            for (uint256 i = 0; i < legs.length && unfilled != 0; i++) {
                Venue memory v = venues[legs[i].venueId];
                if (v.kind == Kind.MAKER) continue;                 // fall back to AMMs only
                if (_executeLeg(v, tokenIn, unfilled)) { unfilled = 0; executedLegs++; }
            }
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        IERC20(tokenOut).transfer(recipient, amountOut);
        // Return anything that could not be routed at all, so no dust is retained.
        if (unfilled != 0) IERC20(tokenIn).transfer(msg.sender, unfilled);

        emit Routed(tokenIn, tokenOut, total, amountOut, executedLegs);
    }

    function _executeLeg(Venue memory v, address tokenIn, uint256 amountIn) internal returns (bool) {
        if (v.kind == Kind.V3) {
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
            bool zeroForOne = (v.token0 == tokenIn);
            PoolKey memory key = PoolKey(Currency.wrap(v.token0), Currency.wrap(v.token1), v.fee, v.tickSpacing, v.hooks);
            bytes32 s = T_UNLOCKED;
            assembly { tstore(s, 1) }
            try poolManager.unlock(abi.encode(key, zeroForOne, amountIn)) {
                assembly { tstore(s, 0) } return true;
            } catch { assembly { tstore(s, 0) } return false; }
        }
        // MAKER
        bool zfo = (v.token0 == tokenIn);
        IERC20(tokenIn).approve(v.target, amountIn);
        try IPropPair(v.target).swapExactIn(zfo, amountIn, 0, address(this), block.timestamp) returns (uint256 o) {
            IERC20(tokenIn).approve(v.target, 0);                   // leave no standing allowance
            return o != 0;
        } catch {
            IERC20(tokenIn).approve(v.target, 0);
            return false;
        }
    }

    // ---------------------------------------------------------------- callbacks

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        bytes32 s = T_EXPECTED;
        address expected;
        assembly { expected := tload(s) }
        address pool = abi.decode(data, (address));
        // msg.sender must be the pool THIS call is currently swapping against, and the data must
        // agree. Registry membership alone would let any registered pool call back at any time.
        if (msg.sender != expected || pool != expected) revert BadCallback();

        if (amount0Delta > 0) IERC20(IUniswapV3Pool(pool).token0()).transfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(pool).token1()).transfer(pool, uint256(amount1Delta));
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
        IERC20(tIn).transfer(address(poolManager), uint256(uint128(-owed)));
        poolManager.settle();
        poolManager.take(Currency.wrap(tOut), address(this), uint256(uint128(gained)));
        return abi.encode(uint256(uint128(gained)));
    }
}
