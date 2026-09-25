// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShortFillPool, ShortFillPair, DoubleCallbackPool} from "./Mocks.sol";

/// R-06, R-07, R-08 (were MEDIUM / LOW / LOW) — FIXED. Positive tests.
///
/// R-06: `_execute` returned a boolean meaning "the call did not revert", so a v3 pool that
/// exhausted its liquidity and a propAMM pair that part-filled were both booked as full fills and
/// their residue was stranded permanently in a contract with no sweep. `_execute` now returns
/// MEASURED consumption and both loops drive off it, so the shortfall re-routes and is then
/// refunded to the payer.
///
/// R-07: the callback settled in `IUniswapV3Pool(pool).token0()` — the pool's own claim — rather
/// than the Merkle-committed token. It now pays the committed token, read from transient storage
/// that `_execute` wrote. Reading it from the callback's `data` would have been no fix at all:
/// `data` is supplied by the pool, which is exactly the actor R-07 defends against.
///
/// R-08: the callback honoured any delta the pool asked for. The budget is now a DECREMENTING
/// transient counter, so N callbacks inside one swap share one allowance rather than getting one
/// each — which a per-callback comparison would not have caught.
contract R06_RouterStranding is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    PartitioRouterV2 internal router;
    ShortFillPool internal pool;
    ShortFillPair internal pair;
    ShortFillPool internal liarPool;
    DoubleCallbackPool internal greedy;

    PartitioRouterV2.Venue[] internal venues;
    bytes32[] internal leaves;
    bytes32 internal root;
    address internal trader = address(0xCAFE);

    /// Leaf 0: a v3 pool consuming 95% of every leg.
    /// Leaf 1: a propAMM pair consuming 60%.
    /// Leaf 2: a v3 pool whose leaf says (USDG, AAPL) while its code reports token0() as AMZN.
    /// Leaf 3: a v3 pool that calls the callback twice, asking for the full leg each time.
    function setUp() public {
        pool = new ShortFillPool(USDG, AAPL, 9_500);
        pair = new ShortFillPair(USDG, AAPL, 6_000);
        liarPool = new ShortFillPool(AMZN, AAPL, 10_000);
        greedy = new DoubleCallbackPool(USDG, AAPL);

        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, address(pool), USDG, AAPL, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.MAKER, address(pair), USDG, AAPL, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, address(liarPool), USDG, AAPL, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, address(greedy), USDG, AAPL, 0, 0, address(0)));
        for (uint256 i = 0; i < venues.length; i++) {
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));
        }
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));

        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = AAPL;
        fds[0] = AAPL_FEED;
        router = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
    }

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
        return OracleGuard.Params({maxDevBps: bps, maxFeedAge: 120 hours});
    }

    function _oracleAapl(uint256 usdgIn) internal view returns (uint256) {
        (, int256 answer,,,) = IAgg(AAPL_FEED).latestRoundData();
        uint8 fd = IAgg(AAPL_FEED).decimals();
        return (usdgIn * 1e18 * (10 ** fd)) / (1e6 * uint256(answer));
    }

    // ---------------------------------------------------------------- R-06

    /// A v3 venue consuming 95% of its leg: whatever it declines comes back to the payer and the
    /// router keeps nothing.
    function test_R06_v3ShortFillRefundsTheResidue() public {
        uint256 amt = 1000e6;
        uint256 payout = (_oracleAapl(amt) * 9_800) / 10_000;
        deal(AAPL, address(pool), payout);
        pool.setGive(payout);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        uint256 out = router.swapExactIn(
            USDG, AAPL, _legs1(0, amt), _guard(300), 0, trader, block.timestamp + 300
        );
        vm.stopPrank();

        uint256 stranded = IERC20(USDG).balanceOf(address(router));
        uint256 refunded = IERC20(USDG).balanceOf(trader);
        uint256 consumed = IERC20(USDG).balanceOf(address(pool));
        console2.log("consumed by the venue:", consumed);
        console2.log("refunded to the trader:", refunded);
        console2.log("stranded in the router:", stranded);
        assertEq(stranded, 0, "router must hold nothing");
        assertGt(refunded, 0, "the residue should have come back");
        assertEq(consumed + refunded, amt, "every wei accounted for");
        assertGt(out, 0, "and the swap still delivered");
    }

    /// Same for a short-filling propAMM pair, which the IPropPair NatSpec says to expect.
    function test_R06_makerShortFillRefundsTheResidue() public {
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

        assertGt(out, 0, "maker leg delivered");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router must hold nothing");
        assertEq(
            IERC20(USDG).balanceOf(address(pair)) + IERC20(USDG).balanceOf(trader), amt,
            "every wei accounted for"
        );
        assertGt(IERC20(USDG).balanceOf(trader), 0, "the part it declined comes back");
    }

    /// The guard is now evaluated on what was SPENT, not on what was offered.
    ///
    /// Uses the MAKER venue deliberately: the fallback loop skips maker legs, so a pair that takes
    /// 60% leaves a full 40% unconsumed with nothing to re-route it into. That gap is far wider
    /// than any permitted band, which is what makes this test discriminating — under the old
    /// accounting the guard was handed the whole leg and the same honest fill looked 40% short, so
    /// it failed at every band. A v3 venue would not prove it: the fallback re-routes most of the
    /// shortfall and the residual gap (25 bps here) is smaller than the floor band.
    function test_R06_guardSeesTheAmountActuallySpent() public {
        uint256 amt = 1000e6;
        uint256 consumed = (amt * 6_000) / 10_000;            // the pair takes 60%, no fallback
        uint256 payout = (_oracleAapl(consumed) * 9_950) / 10_000;  // fair price for THAT 60%
        deal(AAPL, address(pair), payout);
        pair.setGive(payout);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        // 50 bps — the tightest band the library allows. Passes only because the basis is the
        // 600 USDG actually spent rather than the 1000 USDG offered.
        uint256 got = router.swapExactIn(
            USDG, AAPL, _legs1(1, amt), _guard(50), 0, trader, block.timestamp + 300
        );
        vm.stopPrank();

        assertEq(got, payout, "delivered the maker's fill");
        assertEq(IERC20(USDG).balanceOf(address(pair)), consumed, "the pair took 60%");
        assertEq(IERC20(USDG).balanceOf(trader), amt - consumed, "the other 40% came back");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router must hold nothing");
    }

    // ---------------------------------------------------------------- R-07

    /// The venue leaf commits token0 = USDG; this pool's code reports AMZN. The router must settle
    /// in the committed token and must not touch an unrelated balance it happens to hold.
    function test_R07_callbackSettlesInTheCommittedTokenNotThePoolsClaim() public {
        uint256 amt = 100e6;
        deal(AMZN, address(router), 5e18);          // residue from some earlier life
        deal(AAPL, address(liarPool), 1e18);
        liarPool.setGive(1e18);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        router.swapExactIn(USDG, AAPL, _legs1(2, amt), _guard(2000), 0, trader, block.timestamp + 300);
        vm.stopPrank();

        assertEq(IERC20(AMZN).balanceOf(address(liarPool)), 0, "AMZN must never leave on a pool's say-so");
        assertEq(IERC20(AMZN).balanceOf(address(router)), 5e18, "the unrelated balance is untouched");
        assertEq(IERC20(USDG).balanceOf(address(liarPool)), amt, "the committed token was paid");
    }

    // ---------------------------------------------------------------- R-08

    /// A single over-draw is refused, and the leg degrades to consuming nothing rather than
    /// draining the call's balance.
    function test_R08_singleOverdrawIsRefused() public {
        uint256 amt = 100e6;
        deal(USDG, address(router), 900e6);        // residue a greedy pool would love
        deal(AAPL, address(pool), 1e18);
        pool.setGive(1e18);
        pool.setOverdraw(1000e6);                  // asks for 10x the leg

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        vm.expectPartialRevert(PartitioRouterV2.NothingRouted.selector);
        router.swapExactIn(USDG, AAPL, _legs1(0, amt), _guard(2000), 0, trader, block.timestamp + 300);
        vm.stopPrank();

        assertEq(IERC20(USDG).balanceOf(address(pool)), 0, "the greedy pool drew nothing");
        assertEq(IERC20(USDG).balanceOf(address(router)), 900e6, "the unrelated residue is intact");
    }

    /// THE CASE A PER-CALLBACK COMPARISON WOULD MISS: two callbacks in one swap, each asking for
    /// the full leg. The budget decrements, so the second is refused and the leg rolls back.
    function test_R08_repeatedCallbacksShareOneBudget() public {
        uint256 amt = 100e6;
        deal(USDG, address(router), 900e6);
        deal(AAPL, address(greedy), 1e18);
        greedy.setGive(1e18);

        deal(USDG, trader, amt);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), amt);
        vm.expectPartialRevert(PartitioRouterV2.NothingRouted.selector);
        router.swapExactIn(USDG, AAPL, _legs1(3, amt), _guard(2000), 0, trader, block.timestamp + 300);
        vm.stopPrank();

        assertEq(IERC20(USDG).balanceOf(address(greedy)), 0, "double-dipping pool drew nothing");
        assertEq(IERC20(USDG).balanceOf(address(router)), 900e6, "the unrelated residue is intact");
    }

    /// The router still has no way to be swept, which is why holding nothing matters.
    function test_routerStillHasNoAdminSurface() public view {
        bytes memory code = address(router).code;
        bytes4[4] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("skim(address)"))
        ];
        for (uint256 f = 0; f < forbidden.length; f++) {
            for (uint256 i = 0; i + 4 <= code.length; i++) {
                if (
                    code[i] == forbidden[f][0] && code[i + 1] == forbidden[f][1]
                        && code[i + 2] == forbidden[f][2] && code[i + 3] == forbidden[f][3]
                ) {
                    revert("router exposes an admin selector");
                }
            }
        }
    }
}

interface IAgg {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
