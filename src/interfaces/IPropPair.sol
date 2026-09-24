// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Rialto propAMM pair interface, per docs.rialto.xyz/developers/standard-interface.
/// @dev The published spec describes `swapExactIn` as callable by RialtoRouter only. On 4663 that
/// is NOT enforced on-chain — see test/PropAmmDirect.t.sol, which settles directly from a contract.
/// Partitio still treats every maker leg as best-effort: the spec is the maker's stated contract and
/// may be enforced by a future deployment, so a reverting or short-filling maker must never brick a
/// route. See the fallback rule in the README.
interface IPropPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getAmountOut(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);
    function swapExactIn(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}
