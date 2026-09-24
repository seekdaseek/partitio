// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PartitioRouter} from "./PartitioRouter.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice A contract that calls partitio. Deliberately minimal and deliberately NOT an EOA:
/// the whole premise is that a contract can route inside its own transaction, so the mainnet
/// proof has to come from one. Stands in for a liquidation callback, a vault rebalance or an
/// agent wallet.
contract PartitioCaller {
    PartitioRouter public immutable router;
    address public immutable owner;

    constructor(PartitioRouter _router) { router = _router; owner = msg.sender; }

    /// @notice Route `amountIn` of `tokenIn` through partitio from inside this contract.
    function route(
        address tokenIn,
        address tokenOut,
        PartitioRouter.Leg[] calldata legs,
        uint256 minOut
    ) external returns (uint256 amountOut) {
        uint256 total;
        for (uint256 i = 0; i < legs.length; i++) total += legs[i].amountIn;
        IERC20(tokenIn).approve(address(router), total);
        amountOut = router.executeSplit(tokenIn, tokenOut, legs, minOut, address(this), block.timestamp + 600);
    }

    function sweep(address token, address to) external {
        require(msg.sender == owner, "not owner");
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }
}
