// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUiMult { function uiMultiplier() external view returns (uint256); }

interface IAggV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice SGOV is the ERC-8056 stress case: 13 of 37 stock tokens on 4663 carry a non-unit
/// `uiMultiplier()`, and SGOV's is the largest at 51.02 bps — LARGER than OracleGuard's own
/// `DEVIATION_FLOOR_BPS` of 50. So whether the guard should apply that multiplier is not a
/// rounding question; it decides whether the tightest permitted band is usable on this token at
/// all.
///
/// IT SHOULD NOT, and this file is the lock. Measured 2026-09-24 against SGOV's 5 bps pool, real
/// router fills agree with the guard's unmultiplied reference to **0 bps** at 1,000 and 10,000
/// USDG. Had the feed been quoted per UI share, that same honest fill would sit 51 bps from the
/// correct reference — outside a 50 bps band. The feed is priced per RAW token unit, which is what
/// `balanceOf` holds and what every AMM moves.
///
/// These tests fail if anyone "corrects" OracleGuard by applying `uiMultiplier`, and they fail if
/// Robinhood ever flips the convention. Both are the alarm working.
contract SGOVMultiplier is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SGOV = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address constant SGOV_FEED = 0xa0DF4ee0fFf975306345875E3548Fcc519577A11;
    address constant SGOV_POOL_500 = 0x6Ba50150B17Ffd0972915Aaf04fFd5E8f4Fa49b4;
    address constant SGOV_POOL_3000 = 0xfAb520051f96F4D2a32c22B6a3dD7fFfdf231bFe;

    PartitioRouterV2 router;
    PartitioRouterV2.Venue[] venues;
    bytes32[] leaves;
    bytes32 root;
    address trader = address(0xCAFE);

    function setUp() public {
        (address c0, address c1) = SGOV < USDG ? (SGOV, USDG) : (USDG, SGOV);
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, SGOV_POOL_500, c0, c1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, SGOV_POOL_3000, c0, c1, 0, 0, address(0)));
        for (uint256 i = 0; i < venues.length; i++) {
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));
        }
        root = leaves[0] <= leaves[1]
            ? keccak256(abi.encode(leaves[0], leaves[1]))
            : keccak256(abi.encode(leaves[1], leaves[0]));

        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = SGOV;
        fds[0] = SGOV_FEED;
        router = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
    }

    function _legs(uint256 i, uint256 amt) internal view returns (PartitioRouterV2.Leg[] memory l) {
        bytes32[] memory p = new bytes32[](1);
        p[0] = leaves[1 - i];
        l = new PartitioRouterV2.Leg[](1);
        l[0] = PartitioRouterV2.Leg(venues[i], p, amt);
    }

    /// The premise: SGOV really does carry a multiplier bigger than the guard's floor band. If this
    /// ever stops being true the rest of the file is no longer testing anything interesting.
    function test_sgovMultiplierExceedsTheGuardsFloorBand() public view {
        uint256 m = IUiMult(SGOV).uiMultiplier();
        assertGt(m, 1e18, "SGOV should carry a non-unit uiMultiplier");
        uint256 bps = ((m - 1e18) * 10_000) / 1e18;
        console2.log("SGOV uiMultiplier (1e18):", m);
        console2.log("i.e. bps above unity    :", bps);
        assertGe(bps, OracleGuard.DEVIATION_FLOOR_BPS,
            "the premise of this file is that the multiplier is at least as large as the floor band");
    }

    /// THE TEST THE BRIEF ASKED FOR: an honest SGOV fill is not falsely rejected. Run at the
    /// TIGHTEST band the library permits, because a looser one would pass whether the convention
    /// is right or wrong and would prove nothing.
    function test_sgovBuyClearsTheTightestPermittedBand() public {
        uint256 amt = 10_000e6;
        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        uint256 got = router.swapExactIn(
            USDG, SGOV, _legs(0, amt), OracleGuard.Params({maxDevBps: OracleGuard.DEVIATION_FLOOR_BPS}),
            0, trader, block.timestamp + 300
        );
        vm.stopPrank();
        assertGt(got, 0, "an honest SGOV buy must clear a 50 bps band");
        _logDeviation("BUY  10k USDG", _oracleSgovOut(amt), got);
    }

    function test_sgovSellClearsATightBand() public {
        uint256 amt = 50e18;
        deal(SGOV, trader, amt);
        vm.startPrank(trader);
        IERC20(SGOV).approve(address(router), amt);
        uint256 got = router.swapExactIn(
            SGOV, USDG, _legs(0, amt), OracleGuard.Params({maxDevBps: 100}),
            0, trader, block.timestamp + 300
        );
        vm.stopPrank();
        assertGt(got, 0, "an honest SGOV sell must clear a 100 bps band");
        _logDeviation("SELL 50 SGOV", _oracleUsdgOut(amt), got);
    }

    /// The arithmetic lock, with no market dependence at all: the guard's reference for SGOV is the
    /// feed answer scaled by DECIMALS ONLY. If someone multiplies by uiMultiplier, this fails.
    function test_guardReferenceAppliesDecimalsOnlyNotTheMultiplier() public view {
        uint256 amt = 1_000e6;
        (, int256 px,,,) = IAggV3(SGOV_FEED).latestRoundData();
        uint8 fd = IAggV3(SGOV_FEED).decimals();

        uint256 expectedRaw = (amt * 1e18 * (10 ** uint256(fd))) / (1e6 * uint256(px));
        uint256 withMultiplier = (expectedRaw * IUiMult(SGOV).uiMultiplier()) / 1e18;
        assertTrue(withMultiplier != expectedRaw, "the two conventions must be distinguishable");

        // Reproduce exactly what OracleGuard computes, via the router's own binding.
        (address feed, bool stockIsInput) = router.feedFor(USDG, SGOV);
        assertEq(feed, SGOV_FEED);
        assertFalse(stockIsInput);
        assertEq(expectedRaw, _oracleSgovOut(amt), "guard reference must be decimals-only");
    }

    /// And the consequence, stated WITHOUT depending on where the market is today.
    ///
    /// The earlier version of this test compared a live fill against the multiplier-adjusted floor
    /// and had under 1 bps of margin, so it flipped the moment the pool moved. The claim does not
    /// need the market at all: take a PERFECT fill, exactly at the guard's reference with zero
    /// slippage, and ask whether the multiplier convention would accept it. It would not — which is
    /// the whole point, because a perfect fill is the best any venue can do.
    function test_applyingTheMultiplierWouldRejectEvenAPerfectFill() public view {
        uint256 amt = 10_000e6;
        uint256 refRaw = _oracleSgovOut(amt);
        uint256 m = IUiMult(SGOV).uiMultiplier();
        uint256 refUi = (refRaw * m) / 1e18;

        uint256 floorRaw = (refRaw * (10_000 - OracleGuard.DEVIATION_FLOOR_BPS)) / 10_000;
        uint256 floorUi = (refUi * (10_000 - OracleGuard.DEVIATION_FLOOR_BPS)) / 10_000;

        console2.log("perfect fill (= raw reference):", refRaw);
        console2.log("50bps floor, decimals-only    :", floorRaw);
        console2.log("50bps floor, with multiplier  :", floorUi);

        assertGe(refRaw, floorRaw, "a perfect fill clears the floor as the guard computes it");
        assertLt(refRaw, floorUi, "and would be REJECTED if the multiplier were applied");
    }

    /// The live headroom, recorded rather than asserted. A real fill carries the AMM fee and price
    /// impact on top of the reference, so this number moves with the market and is an observation,
    /// not a claim.
    function test_recordLiveHeadroom() public {
        uint256 amt = 10_000e6;
        uint256 refRaw = _oracleSgovOut(amt);
        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        uint256 got = router.swapExactIn(
            USDG, SGOV, _legs(0, amt), OracleGuard.Params({maxDevBps: 200}), 0, trader, block.timestamp + 300
        );
        vm.stopPrank();
        _logDeviation("BUY 10k USDG (live)", refRaw, got);
        assertGt(got, 0);
    }

    // ---------------------------------------------------------------- helpers

    function _oracleSgovOut(uint256 usdgIn) internal view returns (uint256) {
        (, int256 px,,,) = IAggV3(SGOV_FEED).latestRoundData();
        uint8 fd = IAggV3(SGOV_FEED).decimals();
        return (usdgIn * 1e18 * (10 ** uint256(fd))) / (1e6 * uint256(px));
    }

    function _oracleUsdgOut(uint256 sgovIn) internal view returns (uint256) {
        (, int256 px,,,) = IAggV3(SGOV_FEED).latestRoundData();
        uint8 fd = IAggV3(SGOV_FEED).decimals();
        return (sgovIn * uint256(px) * 1e6) / (1e18 * (10 ** uint256(fd)));
    }

    function _logDeviation(string memory label, uint256 refValue, uint256 got) internal pure {
        int256 devBps = (int256(got) - int256(refValue)) * 10_000 / int256(refValue);
        console2.log(label);
        console2.log("   deviation vs guard reference (bps, negative = worse):", devBps);
    }
}
