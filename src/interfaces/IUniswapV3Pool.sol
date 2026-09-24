// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Uniswap v3 pool surface partitio needs.
/// @dev Slot0 is deliberately NOT declared as a struct getter: the canonical Uniswap v3
/// deployment on 4663 returns 7 fields, while the `up-v3` fork returns 6. Venues that need
/// slot0 decode it per pool class rather than through one shared signature.
interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
    function factory() external view returns (address);
}

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
