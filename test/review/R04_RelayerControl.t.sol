// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// R-04  MEDIUM  The amount actually routed is the relayer's choice, not the signer's.
/// R-05  MEDIUM  `_legsFor` ignores the output index, so multi-output baskets cannot be filled.
///
/// `_viaRouter(tokenIn, out, legs, amountIn)` uses `amountIn` ONLY as the approval ceiling:
///     IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);
///     ROUTER.swapExactIn(tokenIn, out.token, legs, out.guard, 0, address(this), block.timestamp);
/// PartitioRouterV2 derives what it pulls from `sum(legs[i].amountIn)`, and `legs` lives in the
/// relayer-supplied `Route`, which is not covered by the order signature. So `weightBps` and
/// `amountIn` are upper bounds the relayer may under-shoot at will, and the signer's only real
/// protection is `minOut`.
contract R04_RelayerControl is ReviewBase {
    function setUp() public {
        _baseSetUp([KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    /// The relayer charges the full maxFee, routes 1 USDG of a 1000 USDG order, burns the order's
    /// replay slot and the EIP-3009 authorization, and hands the rest back as "dust". The oracle
    /// guard cannot see this: it is evaluated against what was routed, not against what was signed.
    function test_R04_relayerKeepsMaxFeeWhileRoutingOneThousandthOfTheOrder() public {
        uint256 amt = 1000e6;
        uint256 maxFee = 5e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = _buyOrder(amt, maxFee, 0, bytes32(uint256(21)));
        GaslessEntry.Auth memory a = _auth(o);
        bytes32 oh = entry.hashOrder(o);

        // legs sum to 1 USDG instead of the 995 USDG the order implies
        uint256 routed = 1e6;
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, a, _routerRoute(routed), maxFee);

        console2.log("AAPL delivered (wei)      :", outs[0]);
        console2.log("AAPL a full fill would buy:", _oracleAapl(amt - maxFee));
        console2.log("relayer fee (USDG)        :", IERC20(USDG).balanceOf(relayer));
        console2.log("returned to user (USDG)   :", IERC20(USDG).balanceOf(user));

        // the guard passed: it only ever saw the 1 USDG that was actually routed
        assertGt(outs[0], 0, "the routed sliver did fill");
        assertLt(outs[0], _oracleAapl(amt - maxFee) / 100, "but it is under 1% of the signed order");
        assertEq(IERC20(USDG).balanceOf(relayer), maxFee, "relayer took the whole fee");
        assertEq(IERC20(USDG).balanceOf(user), amt - maxFee - routed, "the rest came back untouched");
        // the user paid 5 USDG in fees to buy 1 USDG of stock
        assertGt(maxFee, routed, "fee exceeds the value actually transacted");
        assertTrue(entry.executed(oh), "order slot consumed");
        // The same signature can never be used again: the user must sign a fresh order and pay
        // another fee.
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntry.AlreadyExecuted.selector, oh));
        entry.fill(o, a, _routerRoute(routed), maxFee);
    }

    // ------------------------------------------------------------------ R-05 baskets

    function _basketOrder(bytes32 salt) internal view returns (GaslessEntry.Order memory o) {
        GaslessEntry.Output[] memory outs = new GaslessEntry.Output[](2);
        outs[0] = GaslessEntry.Output({
            token: AAPL,
            weightBps: 5_000,
            minOut: 0,
            guard: OracleGuard.Params({feed: AAPL_FEED, stockIsInput: false, maxDevBps: 2000})
        });
        outs[1] = GaslessEntry.Output({
            token: AMZN,
            weightBps: 5_000,
            minOut: 0,
            guard: OracleGuard.Params({feed: AMZN_FEED, stockIsInput: false, maxDevBps: 2000})
        });
        o = GaslessEntry.Order({
            owner: user,
            tokenIn: USDG,
            amountIn: 1000e6,
            maxFee: 5e6,
            deadline: block.timestamp + 600,
            salt: salt,
            outputs: outs
        });
    }

    /// Route candidate 1: legs for both stocks. Output 0 is priced against the AAPL feed but the
    /// router also spends on the AMZN leg, so the AAPL output is about half what the guard demands.
    function test_R05_basketUnfillable_bothLegs() public {
        deal(USDG, user, 1000e6);
        GaslessEntry.Order memory o = _basketOrder(bytes32(uint256(22)));
        GaslessEntry.Auth memory a = _auth(o);

        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](2);
        legs[0] = _leg(0, 248e6); // AAPL/USDG
        legs[1] = _leg(2, 248e6); // AMZN/USDG
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: legs});

        vm.prank(relayer);
        vm.expectRevert(); // OracleGuard.BelowOracleFloor on output 0
        entry.fill(o, a, r, 1e6);
    }

    /// Route candidate 2: legs for one stock only. Output 1 is then measured in AMZN while the
    /// router bought AAPL, so the AMZN balance delta is zero.
    function test_R05_basketUnfillable_singleLegSet() public {
        deal(USDG, user, 1000e6);
        GaslessEntry.Order memory o = _basketOrder(bytes32(uint256(23)));
        GaslessEntry.Auth memory a = _auth(o);

        GaslessEntry.Route memory r = _routerRoute(497e6);
        vm.prank(relayer);
        vm.expectRevert(); // BelowOracleFloor on output 1 (zero AMZN out)
        entry.fill(o, a, r, 1e6);
    }

    /// Route candidate 3: no legs at all. The router refuses an empty split.
    function test_R05_basketUnfillable_noLegs() public {
        deal(USDG, user, 1000e6);
        GaslessEntry.Order memory o = _basketOrder(bytes32(uint256(24)));
        GaslessEntry.Auth memory a = _auth(o);

        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(0),
            callData: "",
            aggMinOut: 0,
            legs: new PartitioRouterV2.Leg[](0)
        });
        vm.prank(relayer);
        vm.expectRevert(PartitioRouterV2.NothingRouted.selector);
        entry.fill(o, a, r, 1e6);
    }

    /// Positive control: the identical two stocks CAN each be bought on their own, so the failure
    /// above is `_legsFor` discarding the index, not a bad venue or a bad feed.
    function test_R05_control_eachStockFillsOnItsOwn() public {
        deal(USDG, user, 1000e6);
        GaslessEntry.Order memory o1 = _buyOrder(500e6, 1e6, 0, bytes32(uint256(25)));
        vm.prank(relayer);
        uint256[] memory a1 = entry.fill(o1, _auth(o1), _routerRoute(499e6), 1e6);
        assertGt(a1[0], 0, "AAPL alone fills");

        deal(USDG, user, 500e6);
        GaslessEntry.Order memory o2 = _buyOrder(500e6, 1e6, 0, bytes32(uint256(26)));
        o2.outputs[0].token = AMZN;
        o2.outputs[0].guard = OracleGuard.Params({feed: AMZN_FEED, stockIsInput: false, maxDevBps: 2000});
        GaslessEntry.Route memory r2 =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs1(2, 499e6)});
        vm.prank(relayer);
        uint256[] memory a2 = entry.fill(o2, _auth(o2), r2, 1e6);
        assertGt(a2[0], 0, "AMZN alone fills");
    }
}
