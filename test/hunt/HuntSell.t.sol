// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IUSDG, IERC20Permit} from "../../src/v2/IUSDG.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SkimmingAggregator} from "../review/Mocks.sol";

interface IDomain { function DOMAIN_SEPARATOR() external view returns (bytes32); }
interface IAgg3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// Sell-side half of the hunt over 8db0239..HEAD: the pro-rata fee when the fee comes out of the
/// USDG OUTPUT, and the accept-branch fall-through when tokenIn is the 18-decimal stock.
contract HuntSell is Test {
    GaslessEntry entry;
    PartitioRouterV2 router;
    SkimmingAggregator agg;

    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 userPk = 0xA11CE;
    address user;
    address relayer = address(0xBEEF);

    PartitioRouterV2.Venue[] venues;
    bytes32[] leaves;
    bytes32 root;

    function setUp() public {
        user = vm.addr(userPk);
        agg = new SkimmingAggregator();
        address c0 = AAPL < USDG ? AAPL : USDG;
        address c1 = AAPL < USDG ? USDG : AAPL;
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3,
            0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D, c0, c1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3,
            0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed, c0, c1, 0, 0, address(0)));
        for (uint256 i = 0; i < venues.length; i++)
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));
        root = leaves[0] <= leaves[1] ? keccak256(abi.encode(leaves[0], leaves[1]))
                                      : keccak256(abi.encode(leaves[1], leaves[0]));
        address[] memory toks = new address[](1); toks[0] = AAPL;
        address[] memory fds  = new address[](1); fds[0]  = AAPL_FEED;
        router = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
        entry = new GaslessEntry(IUSDG(USDG), router, [address(agg), address(0), address(0), address(0)]);
    }

    function _legs(uint256 a0) internal view returns (PartitioRouterV2.Leg[] memory legs) {
        legs = new PartitioRouterV2.Leg[](1);
        bytes32[] memory p = new bytes32[](1); p[0] = leaves[1];
        legs[0] = PartitioRouterV2.Leg(venues[0], p, a0);
    }

    function _sellOrder(uint256 amountIn, uint256 maxFee, uint256 minOut, bytes32 salt)
        internal view returns (GaslessEntry.Order memory o)
    {
        if (minOut == 0) minOut = 1;
        o = GaslessEntry.Order({
            owner: user, tokenIn: AAPL, amountIn: amountIn, tokenOut: USDG, minOut: minOut,
            maxFeeUsdg: maxFee, deadline: block.timestamp + 600, salt: salt,
            guard: OracleGuard.Params({maxDevBps: 300, maxFeedAge: 120 hours})});
    }

    function _sellAuth(GaslessEntry.Order memory o) internal view returns (GaslessEntry.Auth memory a) {
        bytes32 oh = entry.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, oh);
        uint256 nonce = IERC20Permit(AAPL).nonces(o.owner);
        bytes32 sh = keccak256(abi.encode(PERMIT_TYPEHASH, o.owner, address(entry), o.amountIn, nonce, o.deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IDomain(AAPL).DOMAIN_SEPARATOR(), sh));
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(userPk, digest);
        a = GaslessEntry.Auth({v: v, r: r, s: s, pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline});
    }

    /// oracle USDG value of `aaplIn` AAPL, no band
    function _oracleUsdg(uint256 aaplIn) internal view returns (uint256) {
        (, int256 answer,,,) = IAgg3(AAPL_FEED).latestRoundData();
        uint8 fd = IAgg3(AAPL_FEED).decimals();
        return (aaplIn * uint256(answer) * (10 ** 6)) / ((10 ** 18) * (10 ** fd));
    }

    function _fillRaw(GaslessEntry.Order memory o, GaslessEntry.Auth memory a,
                      GaslessEntry.Route memory r, uint256 fee)
        internal returns (bool ok, bytes memory err)
    {
        vm.prank(relayer);
        (ok, err) = address(entry).call(abi.encodeCall(GaslessEntry.fill, (o, a, r, fee)));
    }

    // ================================================================= HUNT-6
    /// Sell-side pro-rata: the fee must never exceed MAX_FEE_BPS of the GROSS USDG the trade
    /// actually produced, however small a share of the stock the relayer chooses to transact.
    function testFuzz_hunt6_sellFeeNeverExceedsHalfAPercentOfGrossProceeds(uint256 feeRaw, uint256 eatBps)
        public
    {
        uint256 amt = 3e18;
        uint256 fee = bound(feeRaw, 0, 50e6);            // far above any legitimate cap
        eatBps = bound(eatBps, 1, 10_000);
        uint256 eaten = (amt * eatBps) / 10_000;
        if (eaten == 0) return;

        deal(AAPL, user, amt);
        // the aggregator pays an honest price for the whole order so only the fee logic is tested
        uint256 honest = (_oracleUsdg(amt) * 9_990) / 10_000;
        deal(USDG, address(agg), honest);

        GaslessEntry.Order memory o = _sellOrder(amt, fee, 0, keccak256(abi.encode(feeRaw, eatBps)));
        GaslessEntry.Auth memory a = _sellAuth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (AAPL, eaten, USDG, honest, relayer)),
            aggMinOut: 0,
            legs: _legs(amt)
        });

        uint256 userUsdgBefore = IERC20(USDG).balanceOf(user);
        uint256 relayerUsdgBefore = IERC20(USDG).balanceOf(relayer);
        (bool ok,) = _fillRaw(o, a, r, fee);
        if (!ok) return;

        uint256 gross = (IERC20(USDG).balanceOf(user) - userUsdgBefore)
                      + (IERC20(USDG).balanceOf(relayer) - relayerUsdgBefore);
        uint256 feeKept = IERC20(USDG).balanceOf(relayer) - relayerUsdgBefore;
        assertLe(feeKept, fee, "relayer kept more than it asked for");
        assertLe(feeKept * 10_000, gross * entry.MAX_FEE_BPS(), "fee above 0.50% of gross proceeds");
        // nothing stranded
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "entry kept USDG");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0, "entry kept AAPL");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router kept USDG");
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "router kept AAPL");
    }

    // ================================================================= HUNT-7
    /// The accept-branch fall-through on a SELL: exact conservation of both tokens, and the
    /// user's stock is either sold or returned - never held by either contract.
    function test_hunt7_sellFallThroughConservesBothTokens() public {
        uint256 amt = 3e18;
        uint256 fee = 1e6;
        uint256 eaten = amt / 2;

        deal(AAPL, user, amt);
        uint256 honest = (_oracleUsdg(eaten) * 9_990) / 10_000;
        deal(USDG, address(agg), honest);

        GaslessEntry.Order memory o = _sellOrder(amt, fee, 0, bytes32(uint256(0x970)));
        GaslessEntry.Auth memory a = _sellAuth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (AAPL, eaten, USDG, honest, relayer)),
            aggMinOut: 0,
            legs: _legs(amt)
        });

        (bool ok, bytes memory err) = _fillRaw(o, a, r, fee);
        if (!ok) { console2.logBytes(err); }
        assertTrue(ok, "sell fall-through must settle");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0, "entry kept AAPL");
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "entry kept USDG");
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "router kept AAPL");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router kept USDG");
        console2.log("user USDG:", IERC20(USDG).balanceOf(user));
        console2.log("user AAPL left:", IERC20(AAPL).balanceOf(user));
    }

    // ================================================================= HUNT-8
    /// The dust-remainder brick, from the SELL side: is it symmetric with the buy side?
    function _sellLeaving(uint256 dust) internal returns (bool ok, bytes memory err) {
        uint256 amt = 3e18;
        uint256 fee = 1e6;
        uint256 eaten = amt - dust;
        deal(AAPL, user, amt);
        uint256 honest = (_oracleUsdg(eaten) * 9_990) / 10_000;
        deal(USDG, address(agg), honest);
        GaslessEntry.Order memory o = _sellOrder(amt, fee, 0, bytes32(uint256(0x980 + dust)));
        GaslessEntry.Auth memory a = _sellAuth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (AAPL, eaten, USDG, honest, relayer)),
            aggMinOut: 0,
            legs: _legs(amt)
        });
        (ok, err) = _fillRaw(o, a, r, fee);
    }

    function test_hunt8_sellDustRemainderIsNotSymmetricWithTheBuySide() public {
        (bool ok1,) = _sellLeaving(1);
        console2.log("sell, 1 wei AAPL remainder, settled?", ok1);
        (bool ok2, bytes memory e2) = _sellLeaving(1e9);
        console2.log("sell, 1e9 wei AAPL remainder, settled?", ok2);
        if (!ok2 && e2.length >= 4) { bytes4 s; assembly { s := mload(add(e2, 0x20)) } console2.logBytes4(s); }
    }
}
