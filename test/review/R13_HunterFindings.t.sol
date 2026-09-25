// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {SkimmingAggregator, ShortFillPair} from "./Mocks.sol";
import {IUSDG} from "../../src/v2/IUSDG.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {IPoolManager, PoolKey, SwapParams, Currency, IUnlockCallback} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Findings from the fresh-context re-verification's adversarial hunters, all fixed here.
///
/// H-1 (HIGH, found independently by BOTH hunters): the aggregator ACCEPT branch returned early
/// without ever comparing `spent` to `spendable`. `legSum == spendable` bounds the amount OFFERED;
/// the relayer writes the aggregator's calldata and therefore chooses the amount CONSUMED. So a
/// route that ate a thousandth of the order at an honest price cleared the oracle floor — which is
/// computed on `spent` — skipped the fallback, and collected the full signed fee while burning the
/// order hash. `minOut` would have caught it; nothing in this repo signs a non-zero one.
///
/// H-2 (MEDIUM): the buy-side percentage cap was measured against gross `o.amountIn` and never
/// against what was spent, so the same sliver fill was a 500% fee on the amount transacted while
/// passing a "0.50% of amountIn" check. The sell side was self-limiting because it used the actual
/// proceeds, which hid the asymmetry.
///
/// H-3 (MEDIUM): `unlockCallback` bounded what it paid PER INVOCATION, while the v3 callback
/// decrements a budget precisely because "nothing stops a pool calling back more than once".
/// Stating that threat model in one function and not the other is an asymmetry, not a decision.
///
/// H-4 (LOW): the constructor rejected a duplicate token key but not a duplicate FEED across two
/// tokens — the exact miswiring that already happened on this chain (CRWV pointed at CRCL's feed).
contract R13_HunterFindings is ReviewBase {
    SkimmingAggregator internal agg;

    function setUp() public {
        agg = new SkimmingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    // ---------------------------------------------------------------- H-1

    /// The exact extraction, now impossible: an aggregator accepted at an honest price on a sliver
    /// no longer ends the fill. The remainder routes, and the user is filled on the whole order.
    function test_H1_acceptedAggregatorSliverStillRoutesTheRemainder() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;                       // exactly MAX_FEE_BPS of the gross
        uint256 spendable = amt - fee;
        uint256 sliver = spendable / 1000;       // the aggregator eats 0.1%

        deal(USDG, user, amt);
        // an honest price for the sliver, so the oracle floor cannot be what stops this
        uint256 honestForSliver = (_oracleAapl(sliver) * 9_990) / 10_000;
        deal(AAPL, address(agg), honestForSliver);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(131)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(
                SkimmingAggregator.swap, (USDG, sliver, AAPL, honestForSliver, relayer)
            ),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        vm.prank(relayer);
        uint256 got = entry.fill(o, a, r, fee);

        // the user is filled on the WHOLE order, not on 0.1% of it
        uint256 oracleFull = _oracleAapl(spendable);
        console2.log("oracle value of the full order:", oracleFull);
        console2.log("delivered to the user         :", got);
        assertGt(got, (oracleFull * 9_000) / 10_000, "the remainder must have routed");
        assertEq(IERC20(AAPL).balanceOf(user), got, "and reached the user");

        // and nothing is left anywhere
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "entry kept USDG");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0, "entry kept AAPL");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router kept USDG");
    }

    // ---------------------------------------------------------------- H-2

    /// The fee is pro rata on what was actually spent. A route that transacts a fraction of the
    /// order collects that fraction of the fee — which is what removes the incentive behind H-1
    /// without bricking a legitimate partial fill.
    function test_H2_feeIsProRataOnWhatWasActuallySpent() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;

        // A leg set the router can only partly consume: point at the AMZN venue for part of it, so
        // that leg reverts... no - instead under-deliver via the aggregator and let the router take
        // the rest, then compare the fee to the share actually spent.
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(132)));
        GaslessEntry.Auth memory a = _auth(o);

        uint256 relayerBefore = IERC20(USDG).balanceOf(relayer);
        vm.prank(relayer);
        entry.fill(o, a, _routerRoute(spendable), fee);
        uint256 fullFee = IERC20(USDG).balanceOf(relayer) - relayerBefore;

        // A full fill pays the full fee: pro rata must not quietly under-charge the honest case.
        // The cap's basis is the USDG that actually changed hands, spent + fee, which for a
        // complete fill is exactly amountIn - so 0.50% of the order is reachable, and not a wei
        // more.
        assertEq(fullFee, fee, "a complete fill should pay the whole signed fee");
        assertLe(fullFee * 10_000, amt * entry.MAX_FEE_BPS(), "and stay inside the cap");
    }

    /// With H-1 closed the sliver route no longer under-spends: the remainder routes, so the whole
    /// order is transacted and the whole fee is earned. The cap still binds against what actually
    /// changed hands rather than against the signed size.
    function test_H2_sliverRouteNowSpendsTheWholeOrderSoTheFeeIsEarned() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        uint256 sliver = spendable / 1000;

        deal(USDG, user, amt);
        uint256 honestForSliver = (_oracleAapl(sliver) * 9_990) / 10_000;
        deal(AAPL, address(agg), honestForSliver);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(133)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(
                SkimmingAggregator.swap, (USDG, sliver, AAPL, honestForSliver, relayer)
            ),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        uint256 relayerBefore = IERC20(USDG).balanceOf(relayer);
        vm.prank(relayer);
        entry.fill(o, a, r, fee);

        // the relayer received the sliver it routed through the mock PLUS its fee; the fee itself
        // must still be inside 0.50% of what was actually spent
        uint256 relayerGain = IERC20(USDG).balanceOf(relayer) - relayerBefore;
        uint256 feeTaken = relayerGain - sliver;   // the sliver is what the mock routed, not fee
        console2.log("fee taken:", feeTaken);
        assertEq(feeTaken, fee, "the whole order was spent, so the whole fee is earned");
        assertLe(feeTaken * 10_000, amt * entry.MAX_FEE_BPS(), "fee above the cap on what changed hands");
    }

    /// H-1 POSTSCRIPT, found by the re-verification judge INSIDE the fix: `_fillSingle` set the
    /// named return `usedAgg = true` on the accept branch and then ended with
    /// `return (got, spent, false)`, so `OrderFilled.usedAggregator` was always false. No funds at
    /// risk - and that is exactly why it would have shipped. It blinds off-chain monitoring of the
    /// one branch that carried the hole, on a contract that cannot be patched, so the flag is
    /// asserted here in both directions rather than trusted.
    function test_H1_theUsedAggregatorFlagReportsTheBranchThatActuallyRan() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;

        // --- aggregator path: it consumes the WHOLE order at an honest price, so it is accepted
        deal(USDG, user, amt);
        uint256 honest = (_oracleAapl(spendable) * 9_990) / 10_000;
        deal(AAPL, address(agg), honest);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(135)));
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, spendable, AAPL, honest, address(agg))),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });
        vm.recordLogs();
        vm.prank(relayer);
        entry.fill(o, _auth(o), r, fee);
        assertTrue(_usedAggregatorFromLogs(), "the aggregator branch must report itself");

        // --- router path: same shape, no aggregator
        deal(USDG, user, amt);
        GaslessEntry.Order memory o2 = _buyOrder(amt, fee, 0, bytes32(uint256(136)));
        vm.recordLogs();
        vm.prank(relayer);
        entry.fill(o2, _auth(o2), _routerRoute(spendable), fee);
        assertFalse(_usedAggregatorFromLogs(), "and the partitio branch must not claim it");
    }

    /// Reads the last `OrderFilled` out of the recorded logs and returns its `usedAggregator`.
    function _usedAggregatorFromLogs() internal returns (bool used) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "OrderFilled(address,bytes32,address,address,address,uint256,uint256,uint256,bool)"
        );
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != sig) continue;
            (,,,,, used) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, bool));
            seen = true;
        }
        assertTrue(seen, "no OrderFilled was emitted at all");
    }

    // ---------------------------------------------------------------- H-2, genuinely short

    /// The case pro rata exists for: a venue that CANNOT take the whole leg. Maker legs are skipped
    /// by the router's fallback loop, so a pair taking 60% leaves 40% genuinely unspent - and the
    /// relayer earns 60% of the fee, not all of it.
    function test_H2_aGenuinelyShortSpendEarnsAProportionalFee() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        uint256 consumed = (spendable * 6_000) / 10_000;

        ShortFillPair pair = new ShortFillPair(USDG, AAPL, 6_000);
        PartitioRouterV2.Venue memory mv =
            PartitioRouterV2.Venue(PartitioRouterV2.Kind.MAKER, address(pair), USDG, AAPL, 0, 0, address(0));
        bytes32 mroot = keccak256(bytes.concat(keccak256(abi.encode(mv))));
        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = AAPL; fds[0] = AAPL_FEED;
        PartitioRouterV2 mrouter = new PartitioRouterV2(IPoolManager(PM), mroot, toks, fds);
        GaslessEntry mentry = new GaslessEntry(IUSDG(USDG), mrouter, [address(agg), address(0), address(0), address(0)]);

        uint256 payout = (_oracleAapl(consumed) * 9_950) / 10_000;   // honest for the 60%
        deal(AAPL, address(pair), payout);
        pair.setGive(payout);
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(134)));
        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(mv, new bytes32[](0), spendable);
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: legs});

        bytes32 oh = mentry.hashOrder(o);
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(userPk, oh);
        bytes32 ds = IUSDGDomainR13(USDG).DOMAIN_SEPARATOR();
        bytes32 sh = keccak256(abi.encode(RECEIVE_TYPEHASH, o.owner, address(mentry), o.amountIn, uint256(0), o.deadline, oh));
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(userPk, keccak256(abi.encodePacked("\x19\x01", ds, sh)));
        GaslessEntry.Auth memory a = GaslessEntry.Auth({
            v: v, r: rr, s: ss, pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline});

        uint256 relayerBefore = IERC20(USDG).balanceOf(relayer);
        vm.prank(relayer);
        mentry.fill(o, a, r, fee);
        uint256 feeTaken = IERC20(USDG).balanceOf(relayer) - relayerBefore;

        uint256 expected = (fee * consumed) / spendable;
        console2.log("spendable:", spendable, "consumed:", consumed);
        console2.log("fee signed:", fee, "fee earned:", feeTaken);
        assertEq(feeTaken, expected, "fee should be pro rata on what was actually spent");
        assertLt(feeTaken, fee, "and strictly less than the signed fee");
        assertEq(IERC20(USDG).balanceOf(address(mrouter)), 0, "router must hold nothing");
        assertEq(IERC20(USDG).balanceOf(address(mentry)), 0, "entry must hold nothing");
    }

    // ---------------------------------------------------------------- H-4

    /// One feed may not be bound to two tokens.
    function test_H4_constructorRejectsAFeedBoundToTwoTokens() public {
        address[] memory toks = new address[](2);
        address[] memory fds = new address[](2);
        toks[0] = AAPL; fds[0] = AAPL_FEED;
        toks[1] = AMZN; fds[1] = AAPL_FEED;            // same feed, different token
        vm.expectRevert(PartitioRouterV2.FeedMapBad.selector);
        new PartitioRouterV2(IPoolManager(PM), root, toks, fds);

        // the honest map still deploys
        fds[1] = AMZN_FEED;
        PartitioRouterV2 ok = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
        assertEq(ok.feedOf(AMZN), AMZN_FEED);
    }
}

// ---------------------------------------------------------------- H-3

/// A PoolManager that invokes `unlockCallback` twice inside one `unlock`, and unlike the earlier
/// version of this mock, actually SETTLES the first one so the surrounding swap succeeds. That
/// matters: if the outer call reverts, the flag recording what happened reverts with it and the
/// test cannot tell a refused second callback from a route that simply failed.
///
/// The canonical v4 PoolManager is single-entry, so this is not reachable on 4663 today - but
/// `poolManager` is an immutable constructor argument the router never re-validates, and the v3
/// callback's decrementing budget exists because exactly this assumption was not trusted there.
contract DoubleUnlockManager is IPoolManager {
    address public immutable TOKEN_IN;
    address public immutable TOKEN_OUT;
    uint256 public owedAmount;
    uint256 public giveAmount;
    bool public secondCallReverted;
    bool public sawSecondCall;

    constructor(address tIn, address tOut) { TOKEN_IN = tIn; TOKEN_OUT = tOut; }

    function arm(uint256 owed, uint256 give) external { owedAmount = owed; giveAmount = give; }

    function unlock(bytes calldata data) external returns (bytes memory) {
        IUnlockCallback(msg.sender).unlockCallback(data);
        sawSecondCall = true;
        (bool ok,) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        secondCallReverted = !ok;
        return "";
    }

    /// amount0 in the high 128 bits, amount1 in the low. token0 is the lower address; the router
    /// treats a NEGATIVE amount as owed by itself.
    function swap(PoolKey memory key, SwapParams memory, bytes calldata) external view returns (int256) {
        bool inIsCurrency0 = Currency.unwrap(key.currency0) == TOKEN_IN;
        int128 a0 = inIsCurrency0 ? -int128(int256(owedAmount)) : int128(int256(giveAmount));
        int128 a1 = inIsCurrency0 ? int128(int256(giveAmount)) : -int128(int256(owedAmount));
        return (int256(a0) << 128) | int256(uint256(uint128(a1)));
    }

    function sync(Currency) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(Currency c, address to, uint256 amount) external {
        if (amount > 0) IERC20(Currency.unwrap(c)).transfer(to, amount);
    }
}

contract R13_V4DoubleUnlock is ReviewBase {
    DoubleUnlockManager internal pm;
    PartitioRouterV2 internal v4router;
    PartitioRouterV2.Venue internal v4venue;
    bytes32 internal v4root;

    function setUp() public {
        user = vm.addr(userPk);
        pm = new DoubleUnlockManager(USDG, AAPL);
        (address c0, address c1) = AAPL < USDG ? (AAPL, USDG) : (USDG, AAPL);
        v4venue = PartitioRouterV2.Venue(PartitioRouterV2.Kind.V4, address(0), c0, c1, 3000, 60, address(0));
        v4root = keccak256(bytes.concat(keccak256(abi.encode(v4venue))));

        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = AAPL;
        fds[0] = AAPL_FEED;
        v4router = new PartitioRouterV2(IPoolManager(address(pm)), v4root, toks, fds);
    }

    /// The second `unlockCallback` inside one `unlock` must be refused: the binding is consumed on
    /// entry, mirroring the v3 budget's reasoning rather than contradicting it.
    function test_H3_secondUnlockCallbackInOneUnlockIsRefused() public {
        uint256 amt = 100e6;
        uint256 give = (_oracleAaplAt(amt) * 9_990) / 10_000;   // an honest price, so the guard passes
        pm.arm(amt, give);
        deal(AAPL, address(pm), give);
        deal(USDG, address(this), amt);
        IERC20(USDG).approve(address(v4router), amt);

        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(v4venue, new bytes32[](0), amt);

        // The swap SUCCEEDS, which is the point: a reverting outer call would roll the flag back
        // and the assertion below would be vacuous.
        uint256 got = v4router.swapExactIn(
            USDG, AAPL, legs, OracleGuard.Params({maxDevBps: 2000, maxFeedAge: 120 hours}), 0, address(this), block.timestamp + 300
        );

        assertEq(got, give, "the first callback settled");
        assertTrue(pm.sawSecondCall(), "the mock must actually have tried a second callback");
        assertTrue(pm.secondCallReverted(), "the second unlockCallback must have been refused");
        assertEq(IERC20(USDG).balanceOf(address(v4router)), 0, "router must hold nothing");
        assertEq(IERC20(USDG).balanceOf(address(pm)), amt, "the pool was paid exactly once");
    }

    function _oracleAaplAt(uint256 usdgIn) internal view returns (uint256) {
        (, int256 answer,,,) = IAggR13(AAPL_FEED).latestRoundData();
        uint8 fd = IAggR13(AAPL_FEED).decimals();
        return (usdgIn * 1e18 * (10 ** fd)) / (1e6 * uint256(answer));
    }

    /// Calling the callback directly, outside any unlock, is still refused.
    function test_H3_unlockCallbackOutsideAnUnlockIsRefused() public {
        vm.prank(address(pm));
        vm.expectRevert(PartitioRouterV2.BadCallback.selector);
        v4router.unlockCallback(hex"00");
    }
}

interface IAggR13 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IUSDGDomainR13 { function DOMAIN_SEPARATOR() external view returns (bytes32); }
