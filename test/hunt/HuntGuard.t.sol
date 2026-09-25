// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IAggregatorV3} from "../../src/v2/IAggregatorV3.sol";
import {GuardHarness} from "../review/GuardHarness.sol";

contract HuntMockFeed is IAggregatorV3 {
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

/// The new `maxFeedAge` field, isolated from the fork so the behaviour is exact.
contract HuntGuard is Test {
    HuntMockFeed feed;
    GuardHarness h;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new HuntMockFeed(336_00000000, block.timestamp, 8);
        h = new GuardHarness();
    }

    function _p(uint256 bps, uint256 age) internal pure returns (OracleGuard.Params memory) {
        return OracleGuard.Params({maxDevBps: bps, maxFeedAge: age});
    }

    /// The signer's bound is only evaluated when `block.timestamp > updatedAt`. A feed reporting a
    /// timestamp AHEAD of the chain clock - up to the library's 5 minute tolerance - skips it
    /// entirely, so `maxFeedAge == 0` ("only a perfectly current reference") is satisfied by a feed
    /// whose clock is wrong in the other direction. The bound FAILS OPEN.
    function test_hunt9_maxFeedAgeIsSkippedEntirelyByAFutureDatedFeed() public {
        // exactly at the library's future tolerance minus one second
        feed.set(336_00000000, block.timestamp + 5 minutes - 1);
        // stockIsInput = true, 1e18 stock -> 6dp USD; honest output so only the age gate is tested
        (uint256 ref,) = h.oracleOut(address(feed), true, 1e18, 18, 6);
        (uint256 floorOut,) = h.enforce(_p(50, 0), address(feed), true, 1e18, ref, 18, 6);
        console2.log("maxFeedAge = 0 accepted a feed dated 299s in the FUTURE. floor:", floorOut);
        assertGt(floorOut, 0, "enforce should have returned a floor, i.e. not reverted");
    }

    /// Control: one second of real age is enough to trip the same zero bound.
    function test_hunt9_control_oneSecondOfRealAgeTripsTheSameBound() public {
        feed.set(336_00000000, block.timestamp - 1);
        (uint256 ref,) = h.oracleOut(address(feed), true, 1e18, 18, 6);
        vm.expectPartialRevert(OracleGuard.FeedOlderThanSignerAllows.selector);
        h.enforce(_p(50, 0), address(feed), true, 1e18, ref, 18, 6);
    }

    /// The library's own 120h ceiling still binds above any signer value, so `maxFeedAge` really
    /// can only be tighter - the author's claim holds.
    function test_hunt9_signerBoundCannotLoosenTheLibraryCeiling() public {
        feed.set(336_00000000, block.timestamp - 121 hours);
        vm.expectPartialRevert(OracleGuard.FeedDead.selector);
        h.enforce(_p(50, type(uint256).max), address(feed), true, 1e18, type(uint256).max, 18, 6);
    }

    /// How tight can a signer make it before the order stops being fillable? The library's own
    /// docs measure SPY's median feed age at 5.9h and p90 at 19.8h, so any bound in the range
    /// where a market gap actually matters is a self-inflicted brick.
    function test_hunt9_aBoundTightEnoughToMatterMakesTheOrderUnfillable() public {
        feed.set(336_00000000, block.timestamp - 6 hours);   // a perfectly normal age for these feeds
        (uint256 ref,) = h.oracleOut(address(feed), true, 1e18, 18, 6);

        vm.expectPartialRevert(OracleGuard.FeedOlderThanSignerAllows.selector);
        h.enforce(_p(50, 1 hours), address(feed), true, 1e18, ref, 18, 6);   // 1h: unfillable

        (uint256 f2,) = h.enforce(_p(50, 24 hours), address(feed), true, 1e18, ref, 18, 6);
        assertGt(f2, 0, "24h bound fills - and is 24h of gap risk");
    }
}
