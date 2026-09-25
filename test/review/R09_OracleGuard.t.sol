// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {GuardHarness} from "./GuardHarness.sol";
import {MockFeed} from "./Mocks.sol";

/// R-09  MEDIUM  `Params.feed` is caller-supplied, unvalidated and unbound to the tokens traded.
/// R-10  LOW     `updatedAt` in the future skips the dead-feed ceiling entirely.
/// Plus the decimals / sign / staleness matrix the brief asks for, most of which is clean.
contract R09_OracleGuard is Test {
    GuardHarness internal h;

    uint8 constant D6 = 6;
    uint8 constant D18 = 18;

    function setUp() public {
        h = new GuardHarness();
        vm.warp(1_790_000_000); // a plausible 2026 timestamp; the library reads block.timestamp
    }

    /// Params is now just the band: the feed and the direction are the router's to supply.
    function _p(uint256 bps) internal pure returns (OracleGuard.Params memory) {
        return OracleGuard.Params({maxDevBps: bps, maxFeedAge: 120 hours});
    }

    // ---------------------------------------------------------------- R-09

    /// R-09 (was MEDIUM) — FIXED by removal. The caller can no longer supply a feed at all:
    /// `Params` is just the band, and `PartitioRouterV2` reads the feed off an immutable map keyed
    /// by the stock token. These tests live in test/review/R09_FeedBinding.t.sol, which exercises
    /// the router; what remains here is the library's arithmetic, which is still worth fuzzing.
    ///
    /// The old tests `test_R09_wrongFeedSilentlyLowersTheFloor` and
    /// `test_R09_attackerSuppliedFeedMakesTheFloorZero` are deleted rather than inverted: they
    /// constructed `Params({feed: ...})`, and that field does not exist, so there is nothing left
    /// to assert at this layer.

    // ---------------------------------------------------------------- R-10 + staleness matrix

    /// R-10 (was LOW) — FIXED. A timestamp far in the future used to skip the dead-feed ceiling
    /// entirely, because `block.timestamp - upd` is never evaluated when `upd` is ahead.
    function test_R10_futureUpdatedAtIsRejected() public {
        MockFeed f = new MockFeed(100e8, block.timestamp + 365 days, 8);
        vm.expectRevert(abi.encodeWithSelector(
            OracleGuard.FeedFromTheFuture.selector,
            block.timestamp + 365 days, block.timestamp, uint256(5 minutes)));
        h.oracleOut(address(f), true, 1e18, D18, D6);
    }

    /// The tolerance is NOT zero, and that is a measurement rather than caution. Reading all 37
    /// feeds against one 4663 block on 2026-09-24, TWO were already ahead of block.timestamp —
    /// GLD by 11s and RDDT by 24s — so a zero-tolerance revert would have bricked those two tokens
    /// the moment it shipped. A lead inside the tolerance must still be accepted.
    function test_R10_smallForwardSkewIsStillAccepted() public {
        MockFeed f = new MockFeed(100e8, block.timestamp + 30, 8);
        (uint256 out,) = h.oracleOut(address(f), true, 1e18, D18, D6);
        assertGt(out, 0, "a 30s lead must not brick the feed");

        MockFeed g = new MockFeed(100e8, block.timestamp + 5 minutes, 8);
        (uint256 out2,) = h.oracleOut(address(g), true, 1e18, D18, D6);
        assertGt(out2, 0, "exactly at the tolerance is still alive");

        MockFeed bad = new MockFeed(100e8, block.timestamp + 5 minutes + 1, 8);
        vm.expectPartialRevert(OracleGuard.FeedFromTheFuture.selector);
        h.oracleOut(address(bad), true, 1e18, D18, D6);
    }

    function test_clean_negativeAnswerRejected() public {
        MockFeed f = new MockFeed(-1, block.timestamp, 8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedBadAnswer.selector, int256(-1)));
        h.oracleOut(address(f), true, 1e18, D18, D6);
    }

    function test_clean_zeroAnswerRejected() public {
        MockFeed f = new MockFeed(0, block.timestamp, 8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedBadAnswer.selector, int256(0)));
        h.oracleOut(address(f), true, 1e18, D18, D6);
    }

    function test_clean_neverUpdatedRejected() public {
        MockFeed f = new MockFeed(100e8, 0, 8);
        vm.expectRevert(OracleGuard.FeedNeverUpdated.selector);
        h.oracleOut(address(f), true, 1e18, D18, D6);
    }

    function test_clean_deadFeedBoundaryIsExactly120h() public {
        MockFeed f = new MockFeed(100e8, block.timestamp - 120 hours, 8);
        h.oracleOut(address(f), true, 1e18, D18, D6); // exactly 120h: still alive
        f.set(100e8, block.timestamp - 120 hours - 1);
        vm.expectPartialRevert(OracleGuard.FeedDead.selector);
        h.oracleOut(address(f), true, 1e18, D18, D6);
    }

    function test_clean_bandFloorAndCeiling() public {
        MockFeed f = new MockFeed(100e8, block.timestamp, 8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.BandTooTight.selector, uint256(49), uint256(50)));
        h.enforce(_p(49), address(f), true, 1e18, type(uint256).max, D18, D6);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.BandTooWide.selector, uint256(2001), uint256(2000)));
        h.enforce(_p(2001), address(f), true, 1e18, type(uint256).max, D18, D6);
        h.enforce(_p(50), address(f), true, 1e18, type(uint256).max, D18, D6);
        h.enforce(_p(2000), address(f), true, 1e18, type(uint256).max, D18, D6);
    }

    /// The widest band the library permits is a 20% haircut. Anyone may relay, so this is also the
    /// most an adversarial relayer can extract on the router path while looking compliant.
    function test_widestBandPermitsATwentyPercentHaircut() public {
        MockFeed f = new MockFeed(338_09628128, block.timestamp, 8);
        (uint256 ref,) = h.oracleOut(address(f), true, 10e18, D18, D6);
        (uint256 floorOut,) = h.enforce(_p(2000), address(f), true, 10e18, ref * 80 / 100, D18, D6);
        assertEq(floorOut, ref * 8000 / 10000, "floor is 80% of the oracle");
        console2.log("oracle:", ref, "floor:", floorOut);
    }

    // ---------------------------------------------------------------- decimals / rounding

    /// 6-in / 18-out, 18-in / 6-out and feed decimals 0..18 all round-trip within one wei of the
    /// exact rational value. Checked because the brief asks; found clean.
    function testFuzz_decimalsRoundTripIsExactToOneWei(uint96 amountIn, uint8 feedDec, uint64 price) public {
        vm.assume(price > 0);
        uint256 fd = bound(feedDec, 0, 18);
        vm.assume(amountIn > 0);
        MockFeed f = new MockFeed(int256(uint256(price)), block.timestamp, uint8(fd));
        uint256 scale = 10 ** fd; // uint256 exponent: a uint8 one silently overflows the literal

        (uint256 sellOut,) = h.oracleOut(address(f), true, amountIn, D18, D6);
        uint256 expectSell = (uint256(amountIn) * uint256(price) * 1e6) / (1e18 * scale);
        assertEq(sellOut, expectSell, "stock->usd scaling drifted");

        (uint256 buyOut,) = h.oracleOut(address(f), false, amountIn, D6, D18);
        uint256 expectBuy = (uint256(amountIn) * 1e18 * scale) / (1e6 * uint256(price));
        assertEq(buyOut, expectBuy, "usd->stock scaling drifted");
    }

    /// The floor truncates downward, never upward, so rounding can only ever favour the fill by at
    /// most one wei. Clean.
    function testFuzz_floorNeverRoundsAgainstTheFill(uint96 amountIn, uint16 bps) public {
        bps = uint16(bound(bps, 50, 2000));
        vm.assume(amountIn > 0);
        MockFeed f = new MockFeed(338_09628128, block.timestamp, 8);
        (uint256 ref,) = h.oracleOut(address(f), true, amountIn, D18, D6);
        (uint256 floorOut,) = h.enforce(_p(bps), address(f), true, amountIn, type(uint256).max, D18, D6);
        assertLe(floorOut, ref, "floor exceeded the reference");
        assertGe(floorOut * 10_000 + 9_999, ref * (10_000 - bps), "floor lost more than one wei");
    }

    /// Below roughly 3e9 wei of an 18-decimal stock (about one ten-millionth of a cent) the
    /// stock->USDG floor truncates to zero and the guard accepts any output, including none. The
    /// threshold is economically negligible; recorded so the claim is a measurement, not a hope.
    function test_dustThresholdWhereTheFloorBecomesZero() public {
        MockFeed f = new MockFeed(338_09628128, block.timestamp, 8);
        uint256 lastZero;
        for (uint256 a = 1; a <= 4e9; a = a * 2 + 1) {
            (uint256 ref,) = h.oracleOut(address(f), true, a, D18, D6);
            if (ref == 0) lastZero = a;
        }
        console2.log("largest tested amountIn whose floor is zero (AAPL wei):", lastZero);
        assertGt(lastZero, 0, "a dust window exists");
        assertLt(lastZero, 4e9, "and it is smaller than 4e9 wei, i.e. under 1e-8 USD");
    }
}
