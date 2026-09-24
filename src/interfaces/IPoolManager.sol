// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Uniswap v4 PoolManager surface partitio needs to execute a swap leg.
/// @dev Deployed at 0x8366a39cc670b4001a1121b8f6a443a643e40951 on chain 4663 (Uniswap's own
/// deployments/4663.md, proven on-chain in docs/GATES.md).
type Currency is address;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // negative = exact input
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (int256 delta);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev BalanceDelta packs amount0 in the high 128 bits and amount1 in the low 128 bits.
/// Negative = owed by the caller to the pool; positive = owed by the pool to the caller.
library BalanceDeltaLib {
    function amount0(int256 d) internal pure returns (int128) {
        return int128(d >> 128);
    }
    function amount1(int256 d) internal pure returns (int128) {
        return int128(int256(uint256(uint128(uint256(d)))));
    }
}
