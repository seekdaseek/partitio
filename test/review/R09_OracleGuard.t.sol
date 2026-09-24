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

    function _p(address feed, bool stockIsInput, uint256 bps) internal pure returns (OracleGuard.Params memory) {
        return OracleGuard.Params({feed: feed, stockIsInput: stockIsInput, maxDevBps: bps});
    }

    // ---------------------------------------------------------------- R-09

    /// Nothing ties the feed to the asset. Pricing a $338 stock against a $246 feed produces a
    /// floor 27% too low, and a fill that the correct feed rejects sails through.
    function test_R09_wrongFeedSilentlyLowersTheFloor() public {
        MockFeed aapl = new MockFeed(338_09628128, block.timestamp - 60, 8); // $338.096
        MockFeed amzn = new MockFeed(246_10700000, block.timestamp - 60, 8); // $246.107

        uint256 sell = 10e18; // 10 shares
        uint256 fill = 2_535e6; // 2535 USDG = 75% of the true AAPL value

        // correct feed, 3% band -> rejected
        vm.expectRevert();
        h.enforce(_p(address(aapl), true, 300), sell, fill, D18, D6);

        // wrong (cheaper) feed, same 3% band -> accepted
        (uint256 floorOut,) = h.enforce(_p(address(amzn), true, 300), sell, fill, D18, D6);
        (uint256 trueRef,) = h.oracleOut(_p(address(aapl), true, 300), sell, D18, D6);

        console2.log("true oracle value (USDG):", trueRef);
        console2.log("floor from wrong feed   :", floorOut);
        console2.log("fill accepted           :", fill);
        assertLt(fill, trueRef * 80 / 100, "the fill is more than 20% below true value");
        assertGe(fill, floorOut, "yet it cleared the wrong feed's floor");
    }

    /// Same hole, one step worse: a feed is just an address, so a caller can point at a contract
    /// that returns any number. The guard then computes a floor of zero.
    function test_R09_attackerSuppliedFeedMakesTheFloorZero() public {
        MockFeed fake = new MockFeed(1, block.timestamp, 18); // price 1e-18 USD
        (uint256 floorOut,) = h.enforce(_p(address(fake), true, 50), 1_000e18, 0, D18, D6);
        assertEq(floorOut, 0, "floor collapsed to zero");
    }

    // ---------------------------------------------------------------- R-10 + staleness matrix

    function test_R10_futureUpdatedAtBypassesTheDeadFeedCeiling() public {
        MockFeed f = new MockFeed(100e8, block.timestamp + 365 days, 8);
        (, uint256 upd) = h.oracleOut(_p(address(f), true, 50), 1e18, D18, D6);
        assertEq(upd, block.timestamp + 365 days, "a year-in-the-future timestamp is accepted");
    }

    function test_clean_negativeAnswerRejected() public {
        MockFeed f = new MockFeed(-1, block.timestamp, 8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedBadAnswer.selector, int256(-1)));
        h.oracleOut(_p(address(f), true, 50), 1e18, D18, D6);
    }

    function test_clean_zeroAnswerRejected() public {
        MockFeed f = new MockFeed(0, block.timestamp, 8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.FeedBadAnswer.selector, int256(0)));
        h.oracleOut(_p(address(f), true, 50), 1e18, D18, D6);
    }

    function test_clean_neverUpdatedRejected() public {
        MockFeed f = new MockFeed(100e8, 0, 8);
        vm.expectRevert(OracleGuard.FeedNeverUpdated.selector);
        h.oracleOut(_p(address(f), true, 50), 1e18, D18, D6);
    }

    function test_clean_deadFeedBoundaryIsExactly120h() public {
        MockFeed f = new MockFeed(100e8, block.timestamp - 120 hours, 8);
        h.oracleOut(_p(address(f), true, 50), 1e18, D18, D6); // exactly 120h: still alive
        f.set(100e8, block.timestamp - 120 hours - 1);
        vm.expectRevert();
        h.oracleOut(_p(address(f), true, 50), 1e18, D18, D6);
    }

    function test_clean_bandFloorAndCeiling() public {
        MockFeed f = new MockFeed(100e8, block.timestamp, 8);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.BandTooTight.selector, uint256(49), uint256(50)));
        h.enforce(_p(address(f), true, 49), 1e18, type(uint256).max, D18, D6);
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.BandTooWide.selector, uint256(2001), uint256(2000)));
        h.enforce(_p(address(f), true, 2001), 1e18, type(uint256).max, D18, D6);
        h.enforce(_p(address(f), true, 50), 1e18, type(uint256).max, D18, D6);
        h.enforce(_p(address(f), true, 2000), 1e18, type(uint256).max, D18, D6);
    }

    /// The widest band the library permits is a 20% haircut. Anyone may relay, so this is also the
    /// most an adversarial relayer can extract on the router path while looking compliant.
    function test_widestBandPermitsATwentyPercentHaircut() public {
        MockFeed f = new MockFeed(338_09628128, block.timestamp, 8);
        (uint256 ref,) = h.oracleOut(_p(address(f), true, 2000), 10e18, D18, D6);
        (uint256 floorOut,) = h.enforce(_p(address(f), true, 2000), 10e18, ref * 80 / 100, D18, D6);
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

        (uint256 sellOut,) = h.oracleOut(_p(address(f), true, 50), amountIn, D18, D6);
        uint256 expectSell = (uint256(amountIn) * uint256(price) * 1e6) / (1e18 * scale);
        assertEq(sellOut, expectSell, "stock->usd scaling drifted");

        (uint256 buyOut,) = h.oracleOut(_p(address(f), false, 50), amountIn, D6, D18);
        uint256 expectBuy = (uint256(amountIn) * 1e18 * scale) / (1e6 * uint256(price));
        assertEq(buyOut, expectBuy, "usd->stock scaling drifted");
    }

    /// The floor truncates downward, never upward, so rounding can only ever favour the fill by at
    /// most one wei. Clean.
    function testFuzz_floorNeverRoundsAgainstTheFill(uint96 amountIn, uint16 bps) public {
        bps = uint16(bound(bps, 50, 2000));
        vm.assume(amountIn > 0);
        MockFeed f = new MockFeed(338_09628128, block.timestamp, 8);
        (uint256 ref,) = h.oracleOut(_p(address(f), true, bps), amountIn, D18, D6);
        (uint256 floorOut,) = h.enforce(_p(address(f), true, bps), amountIn, type(uint256).max, D18, D6);
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
            (uint256 ref,) = h.oracleOut(_p(address(f), true, 50), a, D18, D6);
            if (ref == 0) lastZero = a;
        }
        console2.log("largest tested amountIn whose floor is zero (AAPL wei):", lastZero);
        assertGt(lastZero, 0, "a dust window exists");
        assertLt(lastZero, 4e9, "and it is smaller than 4e9 wei, i.e. under 1e-8 USD");
    }
}
