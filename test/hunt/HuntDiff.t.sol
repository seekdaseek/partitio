// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "../review/ReviewBase.sol";
import {SkimmingAggregator} from "../review/Mocks.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IUSDG} from "../../src/v2/IUSDG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Adversarial hunt over b507c6c..HEAD in src/ only.
contract HuntDiff is ReviewBase {
    SkimmingAggregator internal agg;

    function setUp() public {
        agg = new SkimmingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    function _fillRaw(GaslessEntry.Order memory o, GaslessEntry.Auth memory a,
                      GaslessEntry.Route memory r, uint256 fee)
        internal returns (bool ok, bytes memory err)
    {
        vm.prank(relayer);
        (ok, err) = address(entry).call(abi.encodeCall(GaslessEntry.fill, (o, a, r, fee)));
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length < 4) return bytes4(0);
        assembly { s := mload(add(err, 0x20)) }
    }

    // ================================================================= HUNT-1
    // The accept branch no longer returns early, so the remainder is ALWAYS handed to
    // ROUTER.swapExactIn, and that call is not wrapped in try/catch. A remainder the router
    // cannot turn into output reverts the WHOLE fill - including the aggregator leg that was
    // priced honestly and would have settled before this diff.
    function _acceptedAggLeaving(uint256 dust) internal returns (bool ok, bytes memory err) {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        uint256 eaten = spendable - dust;

        deal(USDG, user, amt);
        uint256 honest = (_oracleAapl(eaten) * 9_990) / 10_000;   // 0.1% under oracle: inside the band
        deal(AAPL, address(agg), honest);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(0x901 + dust)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, eaten, AAPL, honest, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });
        (ok, err) = _fillRaw(o, a, r, fee);
    }

    /// CONTROL: the aggregator consumes the whole spendable amount, remainder is zero, fill lands.
    function test_hunt1_control_aggregatorEatsEverythingAndTheFillLands() public {
        (bool ok, bytes memory err) = _acceptedAggLeaving(0);
        if (!ok) console2.logBytes(err);
        assertTrue(ok, "control must settle");
    }

    /// ATTACK/REGRESSION: one wei of USDG left over bricks the entire fill.
    function test_hunt1_oneWeiRemainderBricksTheWholeFill() public {
        (bool ok, bytes memory err) = _acceptedAggLeaving(1);
        console2.log("1 wei remainder, fill succeeded?", ok);
        if (!ok) { console2.log("revert selector:"); console2.logBytes4(_sel(err)); console2.logBytes(err); }
        assertFalse(ok, "EXPECTED the dust remainder to brick the fill");
    }

    /// Same at a slightly larger, still economically meaningless remainder.
    function test_hunt1_thousandthOfACentRemainderBricksTheWholeFill() public {
        (bool ok, bytes memory err) = _acceptedAggLeaving(10);
        console2.log("10 wei remainder, fill succeeded?", ok);
        if (!ok) { console2.logBytes4(_sel(err)); }
        assertFalse(ok, "EXPECTED the dust remainder to brick the fill");
    }

    // ================================================================= HUNT-2
    // Try to beat the pro-rata fee: the relayer picks `fee` and, through the aggregator's
    // calldata, picks how much of the order is actually transacted. Property asserted: the USDG
    // the relayer keeps as fee never exceeds MAX_FEE_BPS of the USDG that left the user.
    function testFuzz_hunt2_feeNeverExceedsHalfAPercentOfWhatLeftTheUser(uint256 feeRaw, uint256 eatBps)
        public
    {
        uint256 amt = 1000e6;
        uint256 fee = bound(feeRaw, 0, 20e6);        // up to 2% of the order, well above the cap
        eatBps = bound(eatBps, 1, 10_000);
        uint256 spendable = amt - fee;
        uint256 eaten = (spendable * eatBps) / 10_000;
        if (eaten == 0) return;

        deal(USDG, user, amt);
        // Deliver an honest price for the WHOLE spendable amount so the aggregate oracle floor is
        // never what stops the fill - only the fee logic is under test.
        uint256 honest = (_oracleAapl(spendable) * 9_990) / 10_000;
        deal(AAPL, address(agg), honest);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, keccak256(abi.encode(feeRaw, eatBps)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, eaten, AAPL, honest, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        uint256 userBefore = IERC20(USDG).balanceOf(user);
        uint256 relayerBefore = IERC20(USDG).balanceOf(relayer);
        (bool ok,) = _fillRaw(o, a, r, fee);
        if (!ok) return;                              // a reverted fill moves nothing

        uint256 userOut = userBefore + amt - IERC20(USDG).balanceOf(user); // USDG that left the user
        uint256 relayerGain = IERC20(USDG).balanceOf(relayer) - relayerBefore;
        // the aggregator routes `eaten` to the relayer as the swap counterparty; the rest is fee
        uint256 feeKept = relayerGain >= eaten ? relayerGain - eaten : 0;
        assertLe(feeKept * 10_000, userOut * entry.MAX_FEE_BPS(), "fee above 0.50% of what left the user");
        assertLe(feeKept, fee, "fee above the amount the relayer asked for");
    }

    // ================================================================= HUNT-3
    // Is the new duplicate-FEED constructor check complete? It compares feeds[i] against every
    // earlier feeds[j]. Two tokens whose feeds are SWAPPED are two distinct feeds, so the check
    // passes - and every floor for both tokens is then priced off the wrong stock.
    function test_hunt3_constructorAcceptsAFullySwappedFeedMap() public {
        address[] memory toks = new address[](2);
        toks[0] = AAPL;
        toks[1] = AMZN;
        address[] memory fds = new address[](2);
        fds[0] = AMZN_FEED;   // AAPL bound to AMZN's aggregator
        fds[1] = AAPL_FEED;   // AMZN bound to AAPL's aggregator

        PartitioRouterV2 miswired = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
        assertEq(miswired.feedOf(AAPL), AMZN_FEED, "swap accepted");

        (address feed, bool stockIsInput) = miswired.feedFor(USDG, AAPL);
        assertEq(feed, AMZN_FEED, "AAPL priced off AMZN");
        assertFalse(stockIsInput);

        // How wrong is the floor? Compare the correct AAPL reference to the miswired one.
        uint256 correct = _oracleAapl(1000e6);
        uint256 wrongRef = _oracleFor(AMZN_FEED, 1000e6);
        console2.log("AAPL out per 1000 USDG, correct feed:", correct);
        console2.log("AAPL out per 1000 USDG, swapped feed:", wrongRef);
        uint256 hi = correct > wrongRef ? correct : wrongRef;
        uint256 lo = correct > wrongRef ? wrongRef : correct;
        console2.log("floor error in bps:", ((hi - lo) * 10_000) / hi);
        assertGt(((hi - lo) * 10_000) / hi, OracleGuard.MAX_DEV_BPS,
            "the swapped map must move the floor further than any band the library permits");
    }

    /// CONTROL: the check the author DID add does fire.
    function test_hunt3_control_duplicateFeedAcrossTwoTokensIsRejected() public {
        address[] memory toks = new address[](2);
        toks[0] = AAPL;
        toks[1] = AMZN;
        address[] memory fds = new address[](2);
        fds[0] = AAPL_FEED;
        fds[1] = AAPL_FEED;
        vm.expectRevert(PartitioRouterV2.FeedMapBad.selector);
        new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
    }

    function _oracleFor(address feed, uint256 usdgIn) internal view returns (uint256) {
        (, int256 answer,,,) = IAgg2(feed).latestRoundData();
        uint8 fd = IAgg2(feed).decimals();
        return (usdgIn * (10 ** 18) * (10 ** fd)) / ((10 ** 6) * uint256(answer));
    }

    // ================================================================= HUNT-4
    // maxFeedAge is a SIGNED field. A zero (a struct default, an old client, a field a wallet
    // does not know to fill) makes the order unfillable for as long as the feed is behind the
    // chain clock - which the library's own docs say is the normal state of these feeds.
    function test_hunt4_maxFeedAgeZeroMakesTheOrderUnfillable() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(0x940)));
        o.guard.maxFeedAge = 0;
        GaslessEntry.Auth memory a = _auth(o);

        (, , , uint256 upd, ) = IAgg2(AAPL_FEED).latestRoundData();
        console2.log("feed age at this block (s):", block.timestamp > upd ? block.timestamp - upd : 0);

        (bool ok, bytes memory err) = _fillRaw(o, a, _routerRoute(amt - fee), fee);
        console2.log("fill with maxFeedAge=0 succeeded?", ok);
        if (!ok) console2.logBytes4(_sel(err));
        assertFalse(ok, "maxFeedAge=0 should have blocked this");
        assertEq(_sel(err), OracleGuard.FeedOlderThanSignerAllows.selector, "wrong reason");
        // and the order hash is NOT burned - the user can still be filled by a correct order
        assertFalse(entry.executed(entry.hashOrder(o)), "order hash must survive a revert");
    }

    // ================================================================= HUNT-5
    // spendable == 0: the ternary guarding the division. Reachable at all?
    function test_hunt5_spendableZeroIsUnreachablePastNothingSpent() public {
        uint256 amt = 5e6;
        uint256 fee = 5e6;              // fee == amountIn  =>  spendable == 0
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(0x950)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs1(0, 0)
        });
        (bool ok, bytes memory err) = _fillRaw(o, a, r, fee);
        console2.log("spendable==0 fill succeeded?", ok);
        if (!ok) console2.logBytes4(_sel(err));
        assertFalse(ok, "spendable == 0 must not settle");
    }
}

interface IAgg2 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
