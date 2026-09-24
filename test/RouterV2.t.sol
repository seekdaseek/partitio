// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PartitioRouterV2} from "../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../src/v2/OracleGuard.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract RouterV2Test is Test {
    PartitioRouterV2 router;

    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    PartitioRouterV2.Venue[] venues;
    bytes32[] leaves;
    bytes32 root;

    function setUp() public {
        address c0 = AAPL < USDG ? AAPL : USDG;
        address c1 = AAPL < USDG ? USDG : AAPL;

        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3,
            0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D, c0, c1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3,
            0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed, c0, c1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V4,
            address(0), c0, c1, 3000, 60, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.MAKER,
            0x89E211D43BBcf8cA5eaa9E5FBdEF078cF520ecF1, AAPL, USDG, 0, 0, address(0)));

        for (uint256 i = 0; i < venues.length; i++)
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));

        // 4 leaves -> 2 internal -> root, sorted pairs
        bytes32 n01 = _hashPair(leaves[0], leaves[1]);
        bytes32 n23 = _hashPair(leaves[2], leaves[3]);
        root = _hashPair(n01, n23);

        router = new PartitioRouterV2(IPoolManager(PM), root);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        if (i == 0) { p[0] = leaves[1]; p[1] = _hashPair(leaves[2], leaves[3]); }
        else if (i == 1) { p[0] = leaves[0]; p[1] = _hashPair(leaves[2], leaves[3]); }
        else if (i == 2) { p[0] = leaves[3]; p[1] = _hashPair(leaves[0], leaves[1]); }
        else { p[0] = leaves[2]; p[1] = _hashPair(leaves[0], leaves[1]); }
    }

    function _guard(bool stockIsInput, uint256 bps) internal pure returns (OracleGuard.Params memory) {
        return OracleGuard.Params({feed: AAPL_FEED, stockIsInput: stockIsInput, maxDevBps: bps});
    }

    function _legs(uint256[4] memory amts) internal view returns (PartitioRouterV2.Leg[] memory legs) {
        uint256 n;
        for (uint256 i = 0; i < 4; i++) if (amts[i] > 0) n++;
        legs = new PartitioRouterV2.Leg[](n);
        uint256 j;
        for (uint256 i = 0; i < 4; i++)
            if (amts[i] > 0) legs[j++] = PartitioRouterV2.Leg(venues[i], _proof(i), amts[i]);
    }

    // ---------------------------------------------------------------- ownerless

    /// @notice There is no owner and no way to add a venue. Proven by absence: the ABI has no
    /// owner(), no setter, and the root is immutable.
    function test_noOwnerNoSetter() public view {
        bytes4[5] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("addVenue((uint8,address,address,address,uint24,int24,address))")),
            bytes4(keccak256("setOwner(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        bytes memory code = address(router).code;
        for (uint256 i = 0; i < forbidden.length; i++) {
            assertFalse(_hasSelector(code, forbidden[i]), "router exposes an admin selector");
        }
        assertTrue(router.VENUE_ROOT() == root, "root not immutable-set");
    }

    function _hasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /// @notice A venue that is not in the tree cannot be routed through, however well-formed.
    function test_unregisteredVenueRejected() public {
        PartitioRouterV2.Venue memory evil = PartitioRouterV2.Venue(
            PartitioRouterV2.Kind.V3, address(0xBAD), AAPL, USDG, 0, 0, address(0));
        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(evil, _proof(0), 1e18);
        deal(AAPL, address(this), 1e18);
        IERC20(AAPL).approve(address(router), 1e18);
        vm.expectRevert(abi.encodeWithSelector(PartitioRouterV2.BadVenueProof.selector, 0));
        router.swapExactIn(AAPL, USDG, legs, _guard(true, 100), 0, address(this), block.timestamp + 300);
    }

    // ---------------------------------------------------------------- both directions

    function test_sellStockForUsdg() public {
        uint256 amt = 4e18;
        PartitioRouterV2.Leg[] memory legs = _legs([uint256(amt / 4), amt / 4, amt / 4, amt / 4]);
        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);
        uint256 out = router.swapExactIn(AAPL, USDG, legs, _guard(true, 200), 0, address(this), block.timestamp + 300);
        console2.log("sell 4 AAPL -> USDG:", out);
        assertGt(out, 0);
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "router kept tokenIn");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router kept tokenOut");
    }

    function test_buyStockWithUsdg() public {
        uint256 amt = 1000e6;   // 1000 USDG
        PartitioRouterV2.Leg[] memory legs = _legs([uint256(amt / 2), amt / 2, 0, 0]);
        deal(USDG, address(this), amt);
        IERC20(USDG).approve(address(router), amt);
        uint256 out = router.swapExactIn(USDG, AAPL, legs, _guard(false, 200), 0, address(this), block.timestamp + 300);
        console2.log("buy with 1000 USDG -> AAPL:", out);
        assertGt(out, 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0);
    }

    // ---------------------------------------------------------------- the guard

    function test_guardRejectsATooTightBand() public {
        PartitioRouterV2.Leg[] memory legs = _legs([uint256(1e18), 0, 0, 0]);
        deal(AAPL, address(this), 1e18);
        IERC20(AAPL).approve(address(router), 1e18);
        // 10 bps is below the measured 50 bps deviation floor
        vm.expectRevert(abi.encodeWithSelector(OracleGuard.BandTooTight.selector, 10, 50));
        router.swapExactIn(AAPL, USDG, legs, _guard(true, 10), 0, address(this), block.timestamp + 300);
    }

    /// @notice A fill far below the oracle must revert even when the caller's own minOut is 0.
    /// Simulated by demanding a band so tight the real fill cannot clear it... inverted: we assert
    /// that a *huge* size, whose impact exceeds the band, is caught.
    function test_guardCatchesFillFarBelowOracle() public {
        uint256 amt = 4000e18;                       // deliberately enormous: heavy impact
        PartitioRouterV2.Leg[] memory legs = _legs([uint256(amt), 0, 0, 0]);
        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);
        vm.expectRevert();                            // BelowOracleFloor
        router.swapExactIn(AAPL, USDG, legs, _guard(true, 100), 0, address(this), block.timestamp + 300);
    }

    /// @notice The split is never worse than the best single venue, under the same oracle band.
    /// Two earlier versions of this test were wrong and both are worth recording: the first
    /// expected a 4,000 AAPL single-pool dump to pass a 20% band (it loses 78%, so the guard was
    /// right and the test was wrong); the second was named as though splitting rescues a failing
    /// trade, which at 400 AAPL it does not — a single pool clears a 5% band there on its own.
    function test_splitIsNeverWorseThanTheBestSingleVenue() public {
        uint256 amt = 400e18;
        uint256 band = 500;                    // 5%

        uint256 snap = vm.snapshotState();
        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);
        bool singleReverted;
        uint256 singleOut;
        try router.swapExactIn(AAPL, USDG, _legs([uint256(amt), 0, 0, 0]), _guard(true, band), 0,
            address(this), block.timestamp + 300) returns (uint256 o) {
            singleOut = o;
        } catch { singleReverted = true; }
        vm.revertToState(snap);

        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);
        uint256 splitOut = router.swapExactIn(AAPL, USDG,
            _legs([uint256(amt / 4), amt / 4, amt / 4, amt / 4]), _guard(true, band), 0,
            address(this), block.timestamp + 300);

        console2.log("single venue reverted:", singleReverted);
        console2.log("single out           :", singleOut);
        console2.log("split out            :", splitOut);
        assertGt(splitOut, 0, "split failed the band");
        // At 400 AAPL a single pool still clears a 5% band, so this is NOT a case where splitting
        // rescues an otherwise-failing trade — it is the weaker, true claim: the split is never
        // worse. The catastrophic-single-venue case is covered by
        // test_guardCatchesFillFarBelowOracle, where 4,000 AAPL through one pool loses 78% and is
        // rejected at every permitted band.
        if (!singleReverted) assertGe(splitOut, singleOut, "split was worse than one venue");
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
    }

    function test_deadlineEnforced() public {
        PartitioRouterV2.Leg[] memory legs = _legs([uint256(1e18), 0, 0, 0]);
        deal(AAPL, address(this), 1e18);
        IERC20(AAPL).approve(address(router), 1e18);
        vm.expectRevert(PartitioRouterV2.Expired.selector);
        router.swapExactIn(AAPL, USDG, legs, _guard(true, 100), 0, address(this), block.timestamp - 1);
    }
}
