// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {GreedySplit} from "../src/lib/GreedySplit.sol";

/// @notice Solidity side of the Stylus gas table. Same algorithm, same inputs, so the two numbers
/// are comparable. The Stylus figures come from `cast estimate` against the deployed contract on
/// mainnet; these come from a local measurement of the library, which excludes calldata and the
/// 21,000 tx floor. That difference is stated in the README rather than silently absorbed.
contract GasTable is Test {
    function _ladders(uint256 v, uint256 k) internal pure returns (uint256[][] memory L) {
        L = new uint256[][](v);
        for (uint256 i = 0; i < v; i++) {
            L[i] = new uint256[](k);
            uint256 base = 1000 + i * 37;
            for (uint256 n = 1; n <= k; n++) L[i][n - 1] = base * n - n * n * (i + 2);
        }
    }

    function test_gas_2x4() public view {
        uint256[][] memory L = new uint256[][](2);
        L[0] = new uint256[](4); L[1] = new uint256[](4);
        L[0][0]=100; L[0][1]=150; L[0][2]=180; L[0][3]=200;
        L[1][0]=90;  L[1][1]=175; L[1][2]=255; L[1][3]=330;
        uint256 g = gasleft();
        (, uint256 total) = GreedySplit.allocate(L, 4);
        console2.log("solidity 2x4 gas:", g - gasleft(), "total:", total);
    }

    function test_gas_6x8() public view {
        uint256[][] memory L = _ladders(6, 8);
        uint256 g = gasleft();
        (, uint256 total) = GreedySplit.allocate(L, 8);
        console2.log("solidity 6x8 gas:", g - gasleft(), "total:", total);
    }

    function test_gas_12x16() public view {
        uint256[][] memory L = _ladders(12, 16);
        uint256 g = gasleft();
        (, uint256 total) = GreedySplit.allocate(L, 16);
        console2.log("solidity 12x16 gas:", g - gasleft(), "total:", total);
    }

    function test_gas_16x32() public view {
        uint256[][] memory L = _ladders(16, 32);
        uint256 g = gasleft();
        (, uint256 total) = GreedySplit.allocate(L, 32);
        console2.log("solidity 16x32 gas:", g - gasleft(), "total:", total);
    }
}
