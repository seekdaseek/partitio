// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OracleGuard} from "../src/v2/OracleGuard.sol";
import {IAggregatorV3} from "../src/v2/IAggregatorV3.sol";

contract MockFeed is IAggregatorV3 {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public dec;

    constructor(int256 a, uint256 u, uint8 d) { answer = a; updatedAt = u; dec = d; }
    function set(int256 a, uint256 u) external { answer = a; updatedAt = u; }
    function decimals() external view returns (uint8) { return dec; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice The dead-feed ceiling. Everything else in the guard deliberately ignores age — see
/// docs/ORACLE-GUARD.md — so this is the one age check, and it has to sit above every gap the
/// feeds actually exhibit. Measured maximum across 48,512 samples and 32 feeds: 87.4 hours.
contract OracleGuardAgeTest is Test {
    using OracleGuard for OracleGuard.Params;

    MockFeed feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockFeed(336_00000000, block.timestamp, 8); // $336.00, fresh, 8dp
    }

    function _p(uint256 bps) internal view returns (OracleGuard.Params memory) {
        return OracleGuard.Params({maxDevBps: bps});
    }

    /// Helper so the library's internal functions are reachable from the test.
    function oracleOut(address f, bool stockIsInput, uint256 amt, uint8 di, uint8 dou)
        external view returns (uint256 o, uint256 u) {
        return OracleGuard.oracleOut(f, stockIsInput, amt, di, dou);
    }

    function test_freshFeedIsAccepted() public {
        (uint256 out, uint256 upd) = this.oracleOut(address(feed), true, 1e18, 18, 6);
        console2.log("fresh: 1 token ->", out, "USDG(6dp), updatedAt", upd);
        assertEq(out, 336_000000, "expected 336.000000 USDG for 1 token at $336");
    }

    /// 87.4h is the measured maximum real gap. It must still be accepted.
    function test_measuredMaximumGapIsAccepted() public {
        feed.set(336_00000000, block.timestamp - 87 hours - 24 minutes);
        (uint256 out,) = this.oracleOut(address(feed), true, 1e18, 18, 6);
        assertEq(out, 336_000000, "the measured worst-case real gap must not be rejected");
    }

    function test_119hIsAccepted() public {
        feed.set(336_00000000, block.timestamp - 119 hours);
        (uint256 out,) = this.oracleOut(address(feed), true, 1e18, 18, 6);
        assertEq(out, 336_000000);
    }

    /// 121h is past the ceiling: the feed is treated as dead.
    function test_121hIsRejectedAsDead() public {
        uint256 upd = block.timestamp - 121 hours;
        feed.set(336_00000000, upd);
        vm.expectRevert(abi.encodeWithSelector(
            OracleGuard.FeedDead.selector, upd, 121 hours, 120 hours));
        this.oracleOut(address(feed), true, 1e18, 18, 6);
    }

    function test_zeroAnswerRejected() public {
        feed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedBadAnswer.selector, int256(0)));
        this.oracleOut(address(feed), true, 1e18, 18, 6);
    }

    function test_neverUpdatedRejected() public {
        feed.set(336_00000000, 0);
        vm.expectRevert(OracleGuard.FeedNeverUpdated.selector);
        this.oracleOut(address(feed), true, 1e18, 18, 6);
    }

    /// Buying direction: USDG in, stock out.
    function test_buyDirectionScaling() public {
        // stockIsInput = false: USDG in, stock out
        (uint256 out,) = this.oracleOut(address(feed), false, 336_000000, 6, 18);
        console2.log("336 USDG ->", out, "stock wei");
        assertApproxEqRel(out, 1e18, 1e12, "336 USDG should buy ~1 token at $336");
    }
}
