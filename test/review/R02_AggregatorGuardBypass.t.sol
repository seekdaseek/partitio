// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {SkimmingAggregator} from "./Mocks.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// R-02 (was HIGH) — FIXED. R-03 (was MEDIUM) — FIXED. Positive tests.
///
/// The oracle floor is now ONE aggregate check in `fill`, over the input measurably spent and the
/// gross proceeds, run after every branch. Three separate holes are closed by that single move:
///
///   1. The original R-02: the accept branch skipped the guard entirely.
///   2. `agg-reject-path-unguarded` (found by the follow-up audit, and NOT closed by the first
///      fix): a route REJECTED after eating most of the input left everything it consumed
///      unguarded, because the guard lived inside the accept branch and the fallback only guarded
///      the remainder.
///   3. `aggminout-guard-offswitch`: since `aggMinOut` is relayer-supplied and forcing a rejection
///      was how you reached hole 2, that field was an off-switch for the floor.
///
/// R-03: `spent` was `spendable - balanceOf(this)`, i.e. derived from an absolute balance while the
/// fee was still held — it equalled `consumed - fee` and underflowed whenever an aggregator
/// consumed less than the fee. Every external call is now bracketed by its own before/after read.
contract R02_AggregatorGuardBypass is ReviewBase {
    SkimmingAggregator internal agg;

    function setUp() public {
        agg = new SkimmingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    /// The original attack: minOut == 0 and a route that hands everything to the relayer. The
    /// aggregate floor now rejects it.
    function test_R02_skimmingRouteIsRejectedEvenWithMinOutZero() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(11)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, spendable, AAPL, 0, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        vm.prank(relayer);
        vm.expectPartialRevert(OracleGuard.BelowOracleFloor.selector);
        entry.fill(o, a, r, fee);

        assertEq(IERC20(USDG).balanceOf(user), amt, "user must keep their funds");
        assertEq(IERC20(USDG).balanceOf(relayer), 0, "relayer must get nothing");
    }

    /// THE HOLE THE FIRST FIX MISSED. The aggregator is *rejected* on quality after consuming half
    /// the order; the old code then guarded only the remainder the router handled, so half the
    /// order vanished inside a successful fill. The aggregate basis catches it.
    function test_R02_rejectedAggregatorStillCountsAgainstTheFloor() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);
        deal(AAPL, address(agg), 1e18);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(12)));
        GaslessEntry.Auth memory a = _auth(o);
        // consume half, deliver 10 wei of AAPL: `got` is far under any bar, so the branch is
        // REJECTED and the fallback runs on what is left
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, spendable / 2, AAPL, 10, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        vm.prank(relayer);
        vm.expectPartialRevert(OracleGuard.BelowOracleFloor.selector); // full spend, half the proceeds
        entry.fill(o, a, r, fee);
        assertEq(IERC20(USDG).balanceOf(user), amt, "user must keep their funds");
    }

    /// `aggMinOut` is relayer-supplied, so forcing a rejection used to switch the floor off. It is
    /// now only a routing preference: an absurd value still forces the fallback, and the fallback
    /// is guarded like everything else.
    function test_R02_aggMinOutIsNoLongerAnOffSwitch() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);
        deal(AAPL, address(agg), 1e18);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(13)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, spendable, AAPL, 10, relayer)),
            aggMinOut: type(uint256).max,   // guarantees rejection
            legs: _legs1(0, spendable)
        });

        vm.prank(relayer);
        vm.expectPartialRevert(OracleGuard.BelowOracleFloor.selector);
        entry.fill(o, a, r, fee);
        assertEq(IERC20(USDG).balanceOf(user), amt, "user must keep their funds");
    }

    /// An honest aggregator route that beats partitio is still accepted — the guard bounds
    /// catastrophe, it does not forbid using an aggregator.
    function test_R02_honestAggregatorRouteIsStillAccepted() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);

        uint256 fair = (_oracleAapl(spendable) * 9_990) / 10_000;   // 10 bps under the oracle
        deal(AAPL, address(agg), fair);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(14)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, spendable, AAPL, fair, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        vm.prank(relayer);
        uint256 got = entry.fill(o, a, r, fee);
        assertEq(got, fair, "the honest aggregator fill should be delivered");
        assertEq(IERC20(AAPL).balanceOf(user), fair, "and reach the user");
    }

    /// R-03: an aggregator that succeeds while consuming less than the fee used to underflow
    /// `spent` and revert the whole fill instead of falling back. It now falls back cleanly.
    function test_R03_noopAggregatorFallsBackInsteadOfUnderflowing() public {
        uint256 amt = 500e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(15)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.noop, ()),
            aggMinOut: 0,
            legs: _legs1(0, amt - fee)
        });

        vm.prank(relayer);
        uint256 got = entry.fill(o, a, r, fee);
        assertGt(got, 0, "the fallback should have delivered");
        assertGt(got, (_oracleAapl(amt - fee) * 9_000) / 10_000, "and at a sane price");
        assertEq(IERC20(USDG).balanceOf(relayer), fee, "relayer still paid");
    }

    /// A no-op aggregator with minOut == 0 used to be *accepted* as a zero fill, because
    /// `got >= minOut` is `0 >= 0`. It now falls through to the router.
    function test_R02_zeroFillIsNoLongerAcceptedAsAnAggregatorFill() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, 0, 0, bytes32(uint256(16)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.noop, ()),
            aggMinOut: 0,
            legs: _legs1(0, amt)
        });

        vm.prank(relayer);
        uint256 got = entry.fill(o, a, r, 0);
        assertGt(got, 0, "a zero fill must not be accepted as the answer");
        assertEq(IERC20(AAPL).balanceOf(user), got);
    }

    /// Control: the router path rejects the same shortfall, so the two paths agree.
    function test_R02_control_routerPathRejectsTheSameShortfall() public {
        uint256 amt = 4000e18; // dumping 4000 AAPL through one thin pool loses ~78%
        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);
        vm.expectPartialRevert(OracleGuard.BelowOracleFloor.selector);
        router.swapExactIn(
            AAPL, USDG, _legs1(0, amt), OracleGuard.Params({maxDevBps: 2000}), 0,
            address(this), block.timestamp + 300
        );
    }
}
