// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OracleGuard} from "../../src/v2/OracleGuard.sol";

/// @notice External wrapper so the internal library can be fuzzed and revert-tested directly.
contract GuardHarness {
    function oracleOut(OracleGuard.Params memory p, uint256 amountIn, uint8 decIn, uint8 decOut)
        external
        view
        returns (uint256, uint256)
    {
        return OracleGuard.oracleOut(p, amountIn, decIn, decOut);
    }

    function enforce(OracleGuard.Params memory p, uint256 amountIn, uint256 got, uint8 decIn, uint8 decOut)
        external
        view
        returns (uint256, uint256)
    {
        return OracleGuard.enforce(p, amountIn, got, decIn, decOut);
    }
}
