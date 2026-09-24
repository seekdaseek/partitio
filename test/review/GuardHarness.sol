// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OracleGuard} from "../../src/v2/OracleGuard.sol";

/// @notice External wrapper so the internal library can be fuzzed and revert-tested directly.
/// @dev `feed` and `stockIsInput` are arguments rather than fields of Params since R-09: in
/// production they come from PartitioRouterV2's immutable map and from the tokens being traded,
/// never from the caller. This harness passes them explicitly so the library's arithmetic can
/// still be exercised in isolation.
contract GuardHarness {
    function oracleOut(address feed, bool stockIsInput, uint256 amountIn, uint8 decIn, uint8 decOut)
        external
        view
        returns (uint256, uint256)
    {
        return OracleGuard.oracleOut(feed, stockIsInput, amountIn, decIn, decOut);
    }

    function enforce(
        OracleGuard.Params memory p,
        address feed,
        bool stockIsInput,
        uint256 amountIn,
        uint256 got,
        uint8 decIn,
        uint8 decOut
    ) external view returns (uint256, uint256) {
        return OracleGuard.enforce(p, feed, stockIsInput, amountIn, got, decIn, decOut);
    }
}
