// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShortFillPool, ShortFillPair} from "./Mocks.sol";

/// R-06  MEDIUM  A short-filling venue is recorded as a full fill and the residue is stranded.
/// R-07  LOW     The venue leaf commits token0/token1, but settlement uses the pool's own report.
/// R-08  LOW     The v3 callback has no per-leg budget.
///
/// `_execute` decides success from "did the call revert", never from "did it consume amountIn":
///     try IUniswapV3Pool(v.target).swap(...) { return true; } catch { return false; }
///     try IPropPair(v.target).swapExactIn(...) returns (uint256 o) { return o != 0; }
/// A v3 pool that exhausts its liquidity against the price limit, and a propAMM pair that fills
/// part of the size, both return normally having consumed less than `amountIn`. `unfilled` stays
/// zero, so the residue is neither re-routed nor refunded. PartitioRouterV2 has no owner, no sweep
/// and no rescue, and `before = balanceOf(tokenOut)` in every later call excludes whatever is
/// already sitting there - so the residue is unrecoverable by anyone, including the depositor.
contract R06_RouterStranding is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    PartitioRouterV2 internal router;
    ShortFillPool internal pool;
    ShortFillPair internal pair;
    PartitioRouterV2.Venue[] internal venues;
    bytes32[] internal leaves;
    bytes32 internal root;
    address internal trader = address(0xCAFE);

    /// Leaf 0: the short-filling v3 pool, honestly described.
    /// Leaf 1: the short-filling propAMM pair.
    /// Leaf 2: a v3 pool whose leaf says (USDG, AAPL) while the deployed code reports token0()
    ///         as AMZN - the R-07 divergence.
    function setUp() public {
        pool = new ShortFillPool(USDG, AAPL, 9_500); // consumes 95% of every leg
        pair = new ShortFillPair(USDG, AAPL, 6_000); // consumes 60% of every leg
        ShortFillPool liar = new ShortFillPool(AMZN, AAPL, 10_000);

        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, address(pool), USDG, AAPL, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.MAKER, address(pair), USDG, AAPL, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, address(liar), USDG, AAPL, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, address(0xdead), USDG, AAPL, 0, 0, address(0)));
        for (uint256 i = 0; i < venues.length; i++) {
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));
        }
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
        router = new PartitioRouterV2(IPoolManager(PM), root);
        liarPool = liar;
    }

    ShortFillPool internal liarPool;

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        if (i == 0) { p[0] = leaves[1]; p[1] = _pair(leaves[2], leaves[3]); }
        else if (i == 1) { p[0] = leaves[0]; p[1] = _pair(leaves[2], leaves[3]); }
        else if (i == 2) { p[0] = leaves[3]; p[1] = _pair(leaves[0], leaves[1]); }
        else { p[0] = leaves[2]; p[1] = _pair(leaves[0], leaves[1]); }
    }

    function _legs1(uint256 i, uint256 amt) internal view returns (PartitioRouterV2.Leg[] memory legs) {
        legs = new PartitioRouterV2.Leg[](1);
        legs[0] = PartitioRouterV2.Leg(venues[i], _proof(i), amt);
    }

    function _guard(uint256 bps) internal pure returns (OracleGuard.Params memory) {
        return OracleGuard.Params({feed: AAPL_FEED, stockIsInput: false, maxDevBps: bps});
    }

    function _oracleAapl(uint256 usdgIn) internal view returns (uint256) {
        (, int256 answer,,,) = IAgg(AAPL_FEED).latestRoundData();
        uint8 fd = IAgg(AAPL_FEED).decimals();
        return (usdgIn * 1e18 * (10 ** fd)) / (1e6 * uint256(answer));
    }

    // ---------------------------------------------------------------- R-06 v3

    function test_R06_v3ShortFillIsCountedAsSuccessAndResidueIsStranded() public {
        uint256 amt = 1000e6;
        // the pool pays out enough to clear a 3% band computed on the FULL 1000 USDG, so nothing
        // downstream notices that only 950 USDG were actually spent
        uint256 payout = (_oracleAapl(amt) * 9_800) / 10_000;
        deal(AAPL, address(pool), payout);
        pool.setGive(payout);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        vm.recordLogs();
        uint256 out = router.swapExactIn(
            USDG, AAPL, _legs1(0, amt), _guard(300), 0, trader, block.timestamp + 300
        );
        vm.stopPrank();

        uint256 stranded = IERC20(USDG).balanceOf(address(router));
        console2.log("routed (USDG)      :", amt);
        console2.log("pool consumed      :", amt - stranded);
        console2.log("stranded in router :", stranded);
        console2.log("AAPL out           :", out);

        assertEq(stranded, 50e6, "5% of the order is sitting in the router");
        assertEq(IERC20(USDG).balanceOf(trader), 0, "the trader was never refunded");
        assertEq(_legFailedCount(), 0, "no LegFailed event was emitted - it looked like a full fill");
        assertGt(out, 0, "and the swap reported success");
    }

    /// The stranded USDG cannot be recovered: no admin surface, and the balance snapshot in every
    /// later swap deliberately excludes it.
    function test_R06_strandedResidueIsUnrecoverable() public {
        test_R06_v3ShortFillIsCountedAsSuccessAndResidueIsStranded();
        uint256 stranded = IERC20(USDG).balanceOf(address(router));
        assertGt(stranded, 0);

        bytes memory code = address(router).code;
        assertFalse(_hasSel(code, bytes4(keccak256("owner()"))));
        assertFalse(_hasSel(code, bytes4(keccak256("sweep(address)"))));
        assertFalse(_hasSel(code, bytes4(keccak256("rescue(address,uint256)"))));
        assertFalse(_hasSel(code, bytes4(keccak256("skim(address)"))));

        // a later swap that OUTPUTS USDG cannot pick it up either
        uint256 amt = 10e6;
        deal(AAPL, address(pool), 1e18);
        pool.setGive(1e18);
        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        router.swapExactIn(USDG, AAPL, _legs1(0, amt), _guard(2000), 0, trader, block.timestamp + 300);
        vm.stopPrank();
        assertGe(IERC20(USDG).balanceOf(address(router)), stranded, "residue still trapped");
    }

    // ---------------------------------------------------------------- R-06 maker

    function test_R06_makerShortFillStrandsTheResidue() public {
        uint256 amt = 1000e6;
        uint256 payout = (_oracleAapl(amt) * 9_900) / 10_000;
        deal(AAPL, address(pair), payout);
        pair.setGive(payout);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        uint256 out = router.swapExactIn(
            USDG, AAPL, _legs1(1, amt), _guard(300), 0, trader, block.timestamp + 300
        );
        vm.stopPrank();

        assertGt(out, 0, "maker leg reported a fill");
        assertEq(IERC20(USDG).balanceOf(address(router)), 400e6, "40% of the order stranded");
        assertEq(IERC20(USDG).balanceOf(trader), 0, "no refund");
    }

    // ---------------------------------------------------------------- R-07 / R-08

    /// The Merkle leaf commits token0 = USDG, but `uniswapV3SwapCallback` settles with
    /// `IUniswapV3Pool(pool).token0()`, which this venue reports as AMZN. The router therefore
    /// pays out a token the committed leaf never authorised.
    function test_R07_callbackTrustsThePoolsSelfReportedTokensNotTheLeaf() public {
        uint256 amt = 100e6;
        // the router happens to hold AMZN (e.g. residue from an earlier short fill)
        deal(AMZN, address(router), 5e18);
        deal(AAPL, address(liarPool), 1e18);
        liarPool.setGive(1e18);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        router.swapExactIn(USDG, AAPL, _legs1(2, amt), _guard(2000), 0, trader, block.timestamp + 300);
        vm.stopPrank();

        assertEq(IERC20(AMZN).balanceOf(address(liarPool)), 100e6, "AMZN left on the pool's say-so");
        assertEq(IERC20(USDG).balanceOf(address(router)), amt, "the committed token0 was never touched");
    }

    /// The callback honours whatever delta the pool reports. There is no check that it matches the
    /// leg's amountIn, so one registered venue can consume the whole call's budget.
    function test_R08_callbackHasNoPerLegBudget() public {
        uint256 amt = 100e6;
        deal(USDG, address(router), 900e6); // residue from earlier calls
        deal(AAPL, address(pool), 1e18);
        pool.setGive(1e18);
        pool.setOverdraw(1000e6); // asks for 10x the leg size

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        router.swapExactIn(USDG, AAPL, _legs1(0, amt), _guard(2000), 0, trader, block.timestamp + 300);
        vm.stopPrank();

        assertEq(IERC20(USDG).balanceOf(address(pool)), 1000e6, "pool drew 10x the leg it was given");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router emptied");
    }

    // ---------------------------------------------------------------- helpers

    function _legFailedCount() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LegFailed(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) if (logs[i].topics[0] == sig) n++;
    }

    function _hasSel(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}

interface IAgg {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
