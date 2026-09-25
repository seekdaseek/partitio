// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PartitioRouter} from "../src/PartitioRouter.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

/// @notice Router acceptance: invariants I1-I8 against real venues on a pinned fork.
contract PartitioRouterTest is Test {
    PartitioRouter router;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint16 V3_500; uint16 V3_3000; uint16 V4_3000; uint16 MAKER;

    function setUp() public {
        router = new PartitioRouter(IPoolManager(PM));
        address c0 = AAPL < USDG ? AAPL : USDG;
        address c1 = AAPL < USDG ? USDG : AAPL;

        V3_500 = uint16(router.addVenue(PartitioRouter.Venue(
            PartitioRouter.Kind.V3, 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D, c0, c1, 0, 0, address(0))));
        V3_3000 = uint16(router.addVenue(PartitioRouter.Venue(
            PartitioRouter.Kind.V3, 0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed, c0, c1, 0, 0, address(0))));
        V4_3000 = uint16(router.addVenue(PartitioRouter.Venue(
            PartitioRouter.Kind.V4, address(0), c0, c1, 3000, 60, address(0))));
        MAKER = uint16(router.addVenue(PartitioRouter.Venue(
            PartitioRouter.Kind.MAKER, 0x89E211D43BBcf8cA5eaa9E5FBdEF078cF520ecF1, AAPL, USDG, 0, 0, address(0))));
    }

    function _legs4(uint256 a, uint256 b, uint256 c, uint256 d)
        internal view returns (PartitioRouter.Leg[] memory legs)
    {
        legs = new PartitioRouter.Leg[](4);
        legs[0] = PartitioRouter.Leg(V3_500, a);
        legs[1] = PartitioRouter.Leg(V3_3000, b);
        legs[2] = PartitioRouter.Leg(V4_3000, c);
        legs[3] = PartitioRouter.Leg(MAKER, d);
    }

    function _run(PartitioRouter.Leg[] memory legs, uint256 minOut) internal returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < legs.length; i++) total += legs[i].amountIn;
        deal(AAPL, address(this), total);
        IERC20(AAPL).approve(address(router), total);
        return router.executeSplit(AAPL, USDG, legs, minOut, address(this), block.timestamp + 300);
    }

    function _single(uint16 id, uint256 amount) internal returns (uint256) {
        PartitioRouter.Leg[] memory legs = new PartitioRouter.Leg[](1);
        legs[0] = PartitioRouter.Leg(id, amount);
        return _run(legs, 0);
    }

    /// I8: the split must beat the best single venue at size, on EXECUTED output.
    function test_I8_routerSplitBeatsBestSingle() public {
        uint256 amount = 1484e18;                    // ~$500k
        uint256 snap = vm.snapshotState();
        uint256 best;
        uint16[4] memory ids = [V3_500, V3_3000, V4_3000, MAKER];
        for (uint256 i = 0; i < 4; i++) {
            uint256 s2 = vm.snapshotState();
            uint256 o = _single(ids[i], amount);
            if (o > best) best = o;
            vm.revertToState(s2);
        }
        vm.revertToState(snap);

        uint256 q = amount / 4;
        uint256 split = _run(_legs4(q, q, q, amount - 3 * q), 0);

        console2.log("best single venue:", best);
        console2.log("router split     :", split);
        assertGt(split, 0, "nothing routed");
        assertGe(split, best, "I8 VIOLATED: router split worse than best single venue");
        console2.log("gain (bps):", ((split - best) * 10000) / best);
    }

    /// I1: below minOut must revert.
    function test_I1_revertsBelowMinOut() public {
        uint256 amount = 10e18;
        PartitioRouter.Leg[] memory legs = new PartitioRouter.Leg[](1);
        legs[0] = PartitioRouter.Leg(V3_500, amount);
        deal(AAPL, address(this), amount);
        IERC20(AAPL).approve(address(router), amount);
        vm.expectPartialRevert(PartitioRouter.InsufficientOutput.selector);
        router.executeSplit(AAPL, USDG, legs, type(uint256).max, address(this), block.timestamp + 300);
    }

    /// I2: the router retains no token balance.
    function test_I2_routerHoldsNothingAfter() public {
        uint256 q = 100e18;
        _run(_legs4(q, q, q, q), 0);
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "router kept tokenIn");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router kept tokenOut");
    }

    /// I3: no standing allowance is left to any venue.
    function test_I3_noStandingAllowance() public {
        uint256 q = 100e18;
        _run(_legs4(q, q, q, q), 0);
        assertEq(IERC20(AAPL).allowance(address(router), 0x89E211D43BBcf8cA5eaa9E5FBdEF078cF520ecF1), 0,
            "allowance left to maker");
    }

    /// I4: a callback from an address that is not the in-flight pool must revert, even if that
    /// address is a REGISTERED venue. Registry membership alone is not sufficient authentication.
    function test_I4_callbackFromRegisteredButNotInFlightPoolReverts() public {
        vm.prank(0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D);   // a registered v3 pool
        vm.expectRevert(PartitioRouter.BadCallback.selector);
        router.uniswapV3SwapCallback(1, 0, abi.encode(0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D));
    }

    function test_I4_unlockCallbackFromNonPoolManagerReverts() public {
        vm.expectRevert(PartitioRouter.BadCallback.selector);
        router.unlockCallback(abi.encode(uint256(0)));
    }

    /// I7: the deadline is enforced.
    function test_I7_deadlineEnforced() public {
        PartitioRouter.Leg[] memory legs = new PartitioRouter.Leg[](1);
        legs[0] = PartitioRouter.Leg(V3_500, 1e18);
        deal(AAPL, address(this), 1e18);
        IERC20(AAPL).approve(address(router), 1e18);
        vm.expectRevert(PartitioRouter.Expired.selector);
        router.executeSplit(AAPL, USDG, legs, 0, address(this), block.timestamp - 1);
    }

    /// A declining maker must not brick the route: the router falls back to an AMM in the same call.
    function test_makerRefusalFallsBackInSameCall() public {
        uint256 big = 3000e18;                        // well past the maker's cap
        PartitioRouter.Leg[] memory legs = new PartitioRouter.Leg[](2);
        legs[0] = PartitioRouter.Leg(MAKER, big);
        legs[1] = PartitioRouter.Leg(V3_500, 1e18);
        uint256 out = _run(legs, 0);
        console2.log("maker declined, fallback output:", out);
        assertGt(out, 0, "route bricked by a declining maker");
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "tokens stranded in router");
    }

    function test_ownerOnlyCanAddVenues() public {
        vm.prank(address(0xdead));
        vm.expectRevert(PartitioRouter.NotOwner.selector);
        router.addVenue(PartitioRouter.Venue(PartitioRouter.Kind.V3, address(1), AAPL, USDG, 0, 0, address(0)));
    }
}
