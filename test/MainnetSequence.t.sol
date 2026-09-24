// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PartitioRouter} from "../src/PartitioRouter.sol";
import {PartitioCaller} from "../src/PartitioCaller.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
interface IWETH { function deposit() external payable; }

/// @notice Dry run of the exact mainnet sequence, to measure gas before spending real ETH.
/// Mirrors: router deploy, caller deploy, WETH->USDG, USDG->AAPL, AAPL->USDG, all through the
/// caller contract so the proof is "a contract routed", not "an EOA swapped".
contract MainnetSequence is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant WETH_USDG_100 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant AAPL_USDG_500 = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D;

    function test_measureMainnetSequence() public {
        uint256 g;

        g = gasleft();
        PartitioRouter router = new PartitioRouter(IPoolManager(PM));
        uint256 gRouter = g - gasleft();

        g = gasleft();
        PartitioCaller caller = new PartitioCaller(router);
        uint256 gCaller = g - gasleft();

        address w0 = WETH < USDG ? WETH : USDG;
        address w1 = WETH < USDG ? USDG : WETH;
        address a0 = AAPL < USDG ? AAPL : USDG;
        address a1 = AAPL < USDG ? USDG : AAPL;

        g = gasleft();
        uint16 vWeth = uint16(router.addVenue(PartitioRouter.Venue(
            PartitioRouter.Kind.V3, WETH_USDG_100, w0, w1, 0, 0, address(0))));
        uint16 vAapl = uint16(router.addVenue(PartitioRouter.Venue(
            PartitioRouter.Kind.V3, AAPL_USDG_500, a0, a1, 0, 0, address(0))));
        uint256 gVenues = g - gasleft();

        // 1 USD of WETH at the live price
        uint256 wethIn = 0.00038e18;
        deal(WETH, address(caller), wethIn);

        PartitioRouter.Leg[] memory legs = new PartitioRouter.Leg[](1);

        legs[0] = PartitioRouter.Leg(vWeth, wethIn);
        g = gasleft();
        uint256 usdg1 = caller.route(WETH, USDG, legs, 0);
        uint256 gSwap1 = g - gasleft();

        legs[0] = PartitioRouter.Leg(vAapl, usdg1);
        g = gasleft();
        uint256 aapl = caller.route(USDG, AAPL, legs, 0);
        uint256 gSwap2 = g - gasleft();

        legs[0] = PartitioRouter.Leg(vAapl, aapl);
        g = gasleft();
        uint256 usdg2 = caller.route(AAPL, USDG, legs, 0);
        uint256 gSwap3 = g - gasleft();

        console2.log("MEASURED GAS (fork)");
        console2.log("  router deploy :", gRouter);
        console2.log("  caller deploy :", gCaller);
        console2.log("  addVenue x2   :", gVenues);
        console2.log("  WETH -> USDG  :", gSwap1);
        console2.log("  USDG -> AAPL  :", gSwap2);
        console2.log("  AAPL -> USDG  :", gSwap3);
        console2.log("  TOTAL         :", gRouter + gCaller + gVenues + gSwap1 + gSwap2 + gSwap3);
        console2.log("AMOUNTS");
        console2.log("  wethIn  :", wethIn);
        console2.log("  usdg #1 :", usdg1);
        console2.log("  aapl    :", aapl);
        console2.log("  usdg #2 :", usdg2);
        console2.log("  round-trip loss bps:", usdg1 > usdg2 ? ((usdg1 - usdg2) * 10000) / usdg1 : 0);

        assertGt(usdg1, 0, "WETH->USDG produced nothing");
        assertGt(aapl, 0, "USDG->AAPL produced nothing");
        assertGt(usdg2, 0, "AAPL->USDG produced nothing");
    }
}
