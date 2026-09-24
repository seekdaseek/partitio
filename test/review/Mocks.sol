// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3Pool.sol";

/// @notice Models a relayer-crafted aggregator route whose output recipient is not the caller.
/// A real allowlisted aggregator (Kyber's MetaAggregationRouterV2) takes the destination address
/// from calldata, and in GaslessEntry that calldata is chosen by the relayer, not by the signer.
contract SkimmingAggregator {
    function swap(address tokenIn, uint256 amountIn, address outToken, uint256 deliver, address beneficiary)
        external
    {
        IERC20(tokenIn).transferFrom(msg.sender, beneficiary, amountIn);
        if (deliver != 0) IERC20(outToken).transfer(msg.sender, deliver);
    }

    /// Succeeds, consumes nothing, delivers nothing.
    function noop() external {}
}

/// @notice A v3-shaped pool that honours only part of `amountSpecified` - exactly what a real v3
/// pool returns once its liquidity is exhausted against the price limit, and what a short-filling
/// venue looks like from the router's side.
contract ShortFillPool is IUniswapV3SwapCallback {
    address public token0;
    address public token1;
    uint256 public consumeBps;
    uint256 public give;
    /// when set, the callback is asked for this many token0 units regardless of amountSpecified
    uint256 public overdraw;
    constructor(address t0, address t1, uint256 _consumeBps) {
        token0 = t0;
        token1 = t1;
        consumeBps = _consumeBps;
    }

    function setGive(uint256 g) external { give = g; }
    function setOverdraw(uint256 o) external { overdraw = o; }
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 want = overdraw != 0 ? overdraw : (uint256(amountSpecified) * consumeBps) / 10_000;
        address tOut = zeroForOne ? token1 : token0;
        if (give != 0) IERC20(tOut).transfer(recipient, give);
        if (zeroForOne) {
            amount0 = int256(want);
            amount1 = -int256(give);
        } else {
            amount1 = int256(want);
            amount0 = -int256(give);
        }
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {}
}

/// @notice A propAMM pair that reports a non-zero fill while consuming only part of the approval.
/// The IPropPair doc in this repo says short-filling makers are expected and must not brick a
/// route - this is that case.
contract ShortFillPair {
    address public token0;
    address public token1;
    uint256 public consumeBps;
    uint256 public give;

    constructor(address t0, address t1, uint256 _consumeBps) {
        token0 = t0;
        token1 = t1;
        consumeBps = _consumeBps;
    }

    function setGive(uint256 g) external { give = g; }

    function swapExactIn(bool zeroForOne, uint256 amountIn, uint256, address to, uint256)
        external
        payable
        returns (uint256 amountOut)
    {
        uint256 take = (amountIn * consumeBps) / 10_000;
        address tIn = zeroForOne ? token0 : token1;
        address tOut = zeroForOne ? token1 : token0;
        IERC20(tIn).transferFrom(msg.sender, address(this), take);
        amountOut = give;
        IERC20(tOut).transfer(to, amountOut);
    }
}

/// @notice Chainlink AggregatorV3 stub with fully settable round data.
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public dec;

    constructor(int256 a, uint256 u, uint8 d) {
        answer = a;
        updatedAt = u;
        dec = d;
    }

    function set(int256 a, uint256 u) external { answer = a; updatedAt = u; }
    function setDecimals(uint8 d) external { dec = d; }
    function decimals() external view returns (uint8) { return dec; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
