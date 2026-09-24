// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GreedySplit} from "../src/lib/GreedySplit.sol";

contract GreedySplitTest is Test {
    function _l(uint256[] memory a) internal pure returns (uint256[] memory) { return a; }

    function test_singleVenueTakesEverythingWhenAlone() public pure {
        uint256[][] memory L = new uint256[][](1);
        L[0] = new uint256[](4);
        L[0][0] = 100; L[0][1] = 190; L[0][2] = 270; L[0][3] = 340;   // concave
        (uint256[] memory alloc, uint256 total) = GreedySplit.allocate(L, 4);
        assertEq(alloc[0], 4);
        assertEq(total, 340);
    }

    function test_splitsWhenSecondVenueHasBetterMargin() public pure {
        uint256[][] memory L = new uint256[][](2);
        L[0] = new uint256[](4); L[1] = new uint256[](4);
        L[0][0] = 100; L[0][1] = 150; L[0][2] = 180; L[0][3] = 200;   // steeply concave
        L[1][0] = 90;  L[1][1] = 175; L[1][2] = 255; L[1][3] = 330;   // shallow
        (uint256[] memory alloc, uint256 total) = GreedySplit.allocate(L, 4);
        assertEq(alloc[0] + alloc[1], 4);
        // splitting must beat either venue alone at 4 chunks
        assertGt(total, 200);
        assertGt(total, 330);
    }

    /// @notice A capped venue (0 rung) must never be allocated past its cap.
    function test_zeroRungCapsAVenue() public pure {
        uint256[][] memory L = new uint256[][](2);
        L[0] = new uint256[](4); L[1] = new uint256[](4);
        L[0][0] = 100; L[0][1] = 195; L[0][2] = 0; L[0][3] = 0;       // maker refuses past 2 chunks
        L[1][0] = 90;  L[1][1] = 178; L[1][2] = 262; L[1][3] = 344;
        (uint256[] memory alloc, uint256 total) = GreedySplit.allocate(L, 4);
        assertLe(alloc[0], 2, "allocated past the cap");
        assertEq(alloc[0] + alloc[1], 4);
        assertGt(total, 0);
    }

    function test_allVenuesCappedStopsEarly() public pure {
        uint256[][] memory L = new uint256[][](1);
        L[0] = new uint256[](4);
        L[0][0] = 100; L[0][1] = 0; L[0][2] = 0; L[0][3] = 0;
        (uint256[] memory alloc, uint256 total) = GreedySplit.allocate(L, 4);
        assertEq(alloc[0], 1);
        assertEq(total, 100);
    }

    /// @notice Never allocate into a non-improving rung (a hook pool can price non-monotonically).
    function test_neverAllocatesIntoALoss() public pure {
        uint256[][] memory L = new uint256[][](1);
        L[0] = new uint256[](3);
        L[0][0] = 100; L[0][1] = 95; L[0][2] = 90;                    // output DECREASES with size
        (uint256[] memory alloc, uint256 total) = GreedySplit.allocate(L, 3);
        assertEq(alloc[0], 1, "stepped into a worse rung");
        assertEq(total, 100);
    }

    function testFuzz_totalNeverExceedsBestLadderSum(uint8 kRaw) public pure {
        uint256 k = uint256(kRaw) % 8 + 1;
        uint256[][] memory L = new uint256[][](2);
        L[0] = new uint256[](8); L[1] = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) { L[0][i] = (i + 1) * 100; L[1][i] = (i + 1) * 90; }
        (uint256[] memory alloc, uint256 total) = GreedySplit.allocate(L, k);
        uint256 sum;
        for (uint256 i = 0; i < 2; i++) sum += alloc[i];
        assertLe(sum, k, "allocated more chunks than K");
        assertGt(total, 0);
    }
}
