// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "../src/interfaces/IUniswapV3Pool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice G5: prove a contract can execute a real v3 swap on a fork of Robinhood Chain.
/// Deliberately a CONTRACT doing the swap, not an EOA — that is the whole premise of partitio.
contract G5Fork is Test, IUniswapV3SwapCallback {
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    // canonical Uniswap v3 AAPL/USDG, fee 500 — read back from factory.getPool on 4663
    address constant POOL_UNI = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D;
    // `up-v3` fork AAPL/USDG, fee 500 / tickSpacing 60 — an EIP-1167 clone, found via a Kyber route
    address constant POOL_UPV3 = 0x19D55ABa3E5d2C389B7011c634725136dFDcaE33;

    uint160 constant MIN_SQRT = 4295128740;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Pay exactly what the pool asks for. Registry-membership check stands in for
        // CREATE2 derivation here because up-v3 pools are clones (see docs/GATES.md G4).
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "callback: unexpected caller");
        if (amount0Delta > 0) IERC20(IUniswapV3Pool(pool).token0()).transfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IUniswapV3Pool(pool).token1()).transfer(pool, uint256(amount1Delta));
    }

    function _sell(address pool, uint256 amountIn) internal returns (uint256 usdgOut) {
        address t0 = IUniswapV3Pool(pool).token0();
        bool zeroForOne = (t0 == AAPL);
        deal(AAPL, address(this), amountIn);
        uint256 before = IERC20(USDG).balanceOf(address(this));
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT : MAX_SQRT,
            abi.encode(pool)
        );
        usdgOut = IERC20(USDG).balanceOf(address(this)) - before;
        console2.log("  amount0Delta", a0);
        console2.log("  amount1Delta", a1);
    }

    function test_G5_swapOnCanonicalUniswapV3() public {
        uint256 out = _sell(POOL_UNI, 1e18);
        console2.log("canonical v3: 1 AAPL ->", out, "USDG(6dp)");
        assertGt(out, 0, "no USDG received");
        assertGt(out, 300e6, "implausibly low for 1 AAPL");
    }

    function test_G5_swapOnUpV3Fork() public {
        uint256 out = _sell(POOL_UPV3, 1e18);
        console2.log("up-v3 fork : 1 AAPL ->", out, "USDG(6dp)");
        assertGt(out, 0, "no USDG received");
        assertGt(out, 300e6, "implausibly low for 1 AAPL");
    }

    // REMOVED: test_G5_twoVenuesQuoteDifferently asserted that two venues quote differently at
    // 1 AAPL. It proved nothing (two independent pools are almost never bit-identical) and it
    // would flake the moment they happened to agree. The real claim is invariant I8 — that a
    // SPLIT beats the best SINGLE venue at size — and it is tested in test/InvariantI8.t.sol
    // against executed output, not quotes.
}
