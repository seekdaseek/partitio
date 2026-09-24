// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, Currency, BalanceDeltaLib} from "../src/interfaces/IPoolManager.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Proves a contract can execute a Uniswap v4 swap leg on 4663, and — the point of this
/// file — that the V4Quoter figure the evidence engine records is what actually fills.
/// Quotes are not execution. Until this passes, every split_sim number is unverified.
contract V4Exec is Test, IUnlockCallback {
    using BalanceDeltaLib for int256;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint160 constant MIN_SQRT = 4295128740;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    struct Ctx { PoolKey key; bool zeroForOne; uint256 amountIn; }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        bytes memory res = PM.unlock(abi.encode(Ctx(key, zeroForOne, amountIn)));
        out = abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(PM), "unlockCallback: not PoolManager");
        Ctx memory c = abi.decode(data, (Ctx));

        int256 delta = PM.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn),       // negative = exact input
                sqrtPriceLimitX96: c.zeroForOne ? MIN_SQRT : MAX_SQRT
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        address tokenIn  = c.zeroForOne ? Currency.unwrap(c.key.currency0) : Currency.unwrap(c.key.currency1);
        address tokenOut = c.zeroForOne ? Currency.unwrap(c.key.currency1) : Currency.unwrap(c.key.currency0);
        int128 owed = c.zeroForOne ? d0 : d1;
        int128 gained = c.zeroForOne ? d1 : d0;
        require(owed < 0, "expected to owe the input side");
        require(gained > 0, "expected to gain the output side");

        // pay in: sync, transfer, settle
        PM.sync(Currency.wrap(tokenIn));
        IERC20(tokenIn).transfer(address(PM), uint256(uint128(-owed)));
        PM.settle();
        // take out
        PM.take(Currency.wrap(tokenOut), address(this), uint256(uint128(gained)));
        return abi.encode(uint256(uint128(gained)));
    }

    /// @notice A vanilla (hookless) v4 pool: AAPL/USDG fee 3000, tickSpacing 60.
    function test_v4ExecuteHooklessPool() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(AAPL < USDG ? AAPL : USDG),
            currency1: Currency.wrap(AAPL < USDG ? USDG : AAPL),
            fee: 3000, tickSpacing: 60, hooks: address(0)
        });
        bool zeroForOne = (Currency.unwrap(key.currency0) == AAPL);

        uint256 amountIn = 1e18;
        deal(AAPL, address(this), amountIn);
        uint256 before = IERC20(USDG).balanceOf(address(this));
        uint256 out = _swap(key, zeroForOne, amountIn);
        uint256 received = IERC20(USDG).balanceOf(address(this)) - before;

        console2.log("v4 hookless 1 AAPL -> USDG:", received);
        assertEq(out, received, "reported out != balance delta");
        assertGt(received, 300e6, "implausibly low");
    }
}
