// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// R-04 (was MEDIUM) — FIXED. R-05 (was MEDIUM) — REMOVED rather than fixed.
///
/// R-04: `_viaRouter`'s `amountIn` was only an approval ceiling; the amount actually routed came
/// from `route.legs`, which the order signature does not cover, so a relayer could charge the full
/// fee while routing a sliver. The legs are now required to sum to exactly the spendable amount,
/// checked on the RAW legs before `_scaleLegs` rewrites them — checking after would be a tautology,
/// since `_scaleLegs` establishes that sum itself.
///
/// R-05: baskets are gone. `Order` carries one output. The old multi-output path could not be
/// filled by any route, so there is nothing to fix and nothing to ship.
contract R04_RelayerControl is ReviewBase {
    function setUp() public {
        _baseSetUp([KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    /// The exact under-routing attack, now rejected before any money moves.
    function test_R04_slimLegsAreRejected() public {
        uint256 amt = 1000e6;
        uint256 maxFee = 5e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, maxFee, 0, bytes32(uint256(21)));
        GaslessEntry.Auth memory a = _auth(o);

        // legs summing to 1 USDG of a 1000 USDG order
        GaslessEntry.Route memory r = _routerRoute(1e6);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(
            GaslessEntry.LegsDoNotCoverOrder.selector, uint256(1e6), amt - maxFee));
        entry.fill(o, a, r, maxFee);

        // nothing moved, and the order is still fillable with an honest route
        assertEq(IERC20(USDG).balanceOf(user), amt, "user lost funds on a rejected fill");
        assertFalse(entry.executed(entry.hashOrder(o)), "order slot burned by a rejected fill");

        vm.prank(relayer);
        uint256 got = entry.fill(o, a, _routerRoute(amt - maxFee), maxFee);
        assertGt(got, _oracleAapl(amt - maxFee) * 90 / 100, "honest route should fill near the oracle");
    }

    /// Over-routing is refused symmetrically: the relayer cannot route the fee reserve either.
    function test_R04_fatLegsAreRejected() public {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(uint256(22)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = _routerRoute(amt);   // the gross, not the spendable
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(
            GaslessEntry.LegsDoNotCoverOrder.selector, amt, amt - fee));
        entry.fill(o, a, r, fee);
    }

    /// The relayer can still choose the SPLIT, just not the total. Two venues, same total.
    function test_R04_relayerStillChoosesTheSplitNotTheTotal() public {
        uint256 amt = 1000e6;
        uint256 fee = 1e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(23)));

        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](2);
        legs[0] = _leg(0, spendable / 3);
        legs[1] = _leg(1, spendable - spendable / 3);
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: legs});

        GaslessEntry.Auth memory auth78 = _auth(o);
        vm.prank(relayer);
        uint256 got = entry.fill(o, auth78, r, fee);
        assertGt(got, 0, "two-venue split should fill");
        assertEq(IERC20(AAPL).balanceOf(user), got);
    }

    // ---------------------------------------------------------------- R-05

    /// The basket path is gone from the type system: `Order` has one `tokenOut`, and the symbols
    /// that made a basket expressible no longer exist in the ABI.
    function test_R05_basketSurfaceIsGone() public view {
        bytes memory code = address(entry).code;
        bytes4[3] memory gone = [
            bytes4(keccak256("BadWeights(uint256)")),
            bytes4(keccak256("TooManyOutputs(uint256)")),
            bytes4(keccak256("MAX_OUTPUTS()"))
        ];
        for (uint256 g = 0; g < gone.length; g++) {
            for (uint256 i = 0; i + 4 <= code.length; i++) {
                if (
                    code[i] == gone[g][0] && code[i + 1] == gone[g][1] && code[i + 2] == gone[g][2]
                        && code[i + 3] == gone[g][3]
                ) {
                    revert("a basket-path selector is still in the bytecode");
                }
            }
        }
    }

    /// Both stocks still fill individually — R-05 removed the unfillable branch, not the coverage.
    function test_R05_eachStockStillFillsOnItsOwn() public {
        uint256 fee = 1e6;
        deal(USDG, user, 500e6);
        GaslessEntry.Order memory o1 = _buyOrder(500e6, 5e6, 0, bytes32(uint256(25)));
        GaslessEntry.Auth memory auth113 = _auth(o1);
        vm.prank(relayer);
        assertGt(entry.fill(o1, auth113, _routerRoute(500e6 - fee), fee), 0, "AAPL alone fills");

        deal(USDG, user, 500e6);
        GaslessEntry.Order memory o2 = _buyOrder(500e6, 5e6, 0, bytes32(uint256(26)));
        o2.tokenOut = AMZN;
        GaslessEntry.Route memory r2 = GaslessEntry.Route({
            aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs1(2, 500e6 - fee)
        });
        GaslessEntry.Auth memory auth123 = _auth(o2);
        vm.prank(relayer);
        assertGt(entry.fill(o2, auth123, r2, fee), 0, "AMZN alone fills");
    }

    /// NEW (audit finding `router-tokenout-unchecked`): a leg pointing at a correctly-committed
    /// pool for a DIFFERENT quote asset used to pass the proof and the tokenIn check, spend real
    /// input and strand a third token the output delta never counted. Now it reverts.
    function test_routerRejectsALegForTheWrongPair() public {
        uint256 amt = 1000e6;
        uint256 fee = 1e6;
        uint256 spendable = amt - fee;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(27)));

        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](2);
        legs[0] = _leg(0, spendable - 100e6);   // USDG/AAPL - correct
        legs[1] = _leg(2, 100e6);               // USDG/AMZN - committed, but the wrong pair
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: legs});
        // hoisted: _auth makes an external call, which would otherwise consume the expectRevert
        GaslessEntry.Auth memory a = _auth(o);

        vm.prank(relayer);
        vm.expectPartialRevert(PartitioRouterV2.TokenNotInVenue.selector);
        entry.fill(o, a, r, fee);
        assertEq(IERC20(AMZN).balanceOf(address(router)), 0, "no AMZN should ever have been bought");
    }
}
