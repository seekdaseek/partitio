// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {DonatingAggregator} from "./Mocks.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// `r01-spent-donation`, the last PARTIAL the judges left open, closed by a test rather than an
/// argument.
///
/// The judge's condition was: "if Kyber's router cannot be made to transfer an arbitrary token to an
/// arbitrary address, this collapses to CLOSED." It CAN - `srcReceivers` and `dstReceiver` are
/// calldata, and the relayer writes the calldata. So the finding cannot close on Kyber's surface; it
/// has to close on GaslessEntry's accounting.
///
/// WHAT ACTUALLY HAPPENS, which is not what I first wrote down. I expected a mid-call donation of the
/// input token to be REFUNDED to the owner. It is not: `spent` is bracketed around the aggregator
/// call, so input handed back mid-call reads as input the aggregator did not consume, and the
/// fall-through routes it through partitio as the remainder. The owner is filled on the whole order,
/// their outflow is exactly `spent + feeDue`, and the aggregate floor judges the whole trade. A
/// donation is indistinguishable from - and exactly as harmless as - a partial aggregator fill.
contract R15_Donation is ReviewBase {
    DonatingAggregator internal agg;

    function setUp() public {
        agg = new DonatingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    function test_r01_aMidCallDonationIsRoutedAsTheRemainderAndTheAccountingIsExact() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        uint256 donate = 300e6;                          // 30% of the input comes straight back

        uint256 honest = (_oracleAapl(spendable - donate) * 9_990) / 10_000;
        deal(AAPL, address(agg), honest);
        deal(USDG, address(agg), donate);
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(151)));
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(DonatingAggregator.swap, (USDG, spendable, donate, AAPL, honest)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        uint256 userUsdg0 = IERC20(USDG).balanceOf(user);
        uint256 relayer0 = IERC20(USDG).balanceOf(relayer);
        vm.recordLogs();
        GaslessEntry.Auth memory auth56 = _auth(o);
        vm.prank(relayer);
        uint256 out = entry.fill(o, auth56, r, fee);

        uint256 userOutflow = userUsdg0 - IERC20(USDG).balanceOf(user);
        uint256 relayerGain = IERC20(USDG).balanceOf(relayer) - relayer0;
        (uint256 spent, uint256 feeDue, uint256 routerLeg) = _filled();
        console2.log("pulled by the aggregator  :", spendable);
        console2.log("donated back mid-call     :", donate);
        console2.log("routed through partitio   :", routerLeg);
        console2.log("measured spent (total)    :", spent);
        console2.log("owner net USDG outflow    :", userOutflow);

        // the donation came back as unconsumed input and partitio routed exactly that much
        assertEq(routerLeg, donate, "the donated input was routed as the remainder");
        assertEq(spent, spendable, "the owner was filled on the whole order");
        // the owner paid exactly what the guard priced plus the fee - to the wei
        assertEq(userOutflow, spent + feeDue, "outflow == spent + fee");
        assertEq(relayerGain, feeDue, "the relayer's gain is its fee and nothing else");
        // and the output clears the floor computed on that same spend
        uint256 floorOut = (_oracleAapl(spent) * 9_700) / 10_000;
        assertGe(out, floorOut, "the whole trade clears the signed band");
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "entry holds no USDG");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0, "entry holds no AAPL");
    }

    /// Can a donation carry a BAD price past the floor? The aggregator keeps 90% of the input at 5%
    /// under the oracle and hands 10% back. The donated 10% is routed honestly, but the floor is on
    /// the WHOLE trade - 0.95 x 0.90 + 1.0 x 0.10 = 95.5% of fair - outside the signed 300 bps band.
    /// It reverts, and the revert rolls back `executed`, so the order survives for an honest filler.
    function test_r01_aDonationCannotCarryABadPricePastTheAggregateFloor() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        uint256 donate = spendable / 10;
        uint256 bad = (_oracleAapl(spendable - donate) * 9_500) / 10_000;
        deal(AAPL, address(agg), bad);
        deal(USDG, address(agg), donate);
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(152)));
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(DonatingAggregator.swap, (USDG, spendable, donate, AAPL, bad)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });
        GaslessEntry.Auth memory a = _auth(o);
        bytes32 oh = entry.hashOrder(o);
        vm.prank(relayer);
        vm.expectPartialRevert(OracleGuard.BelowOracleFloor.selector);
        entry.fill(o, a, r, fee);
        assertFalse(entry.executed(oh), "a refused fill must not burn the order");
    }

    bytes32 internal constant ROUTED =
        keccak256("Routed(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    function _routedSpent(Vm.Log memory l) internal pure returns (uint256 amountIn) {
        (amountIn,,,,) = abi.decode(l.data, (uint256, uint256, uint256, uint256, uint256));
    }

    /// OrderFilled's (spent, fee) and the router leg's own `amountIn` from its Routed event.
    function _filled() internal returns (uint256 spent, uint256 feeDue, uint256 routerLeg) {
        bytes32 filled = keccak256("OrderFilled(address,bytes32,address,address,address,uint256,uint256,uint256,bool)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == filled) {
                (,, spent,, feeDue,) = abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, bool));
            } else if (logs[i].emitter == address(router) && logs[i].topics[0] == ROUTED) {
                routerLeg += _routedSpent(logs[i]);
            }
        }
    }
}
