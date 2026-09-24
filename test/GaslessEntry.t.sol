// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {GaslessEntry} from "../src/v2/GaslessEntry.sol";
import {PartitioRouterV2} from "../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../src/v2/OracleGuard.sol";
import {IUSDG} from "../src/v2/IUSDG.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice End-to-end against the REAL USDG on a fork. A mock would prove the test, not the
/// integration: USDG on 4663 is a diamond whose `receiveWithAuthorization` enforces
/// `msg.sender == to`, and that property is the whole reason the design is safe.
contract GaslessEntryTest is Test {
    GaslessEntry entry;
    PartitioRouterV2 router;

    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    bytes32 constant RECEIVE_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    uint256 userPk = 0xA11CE;
    address user;
    address relayer = address(0xBEEF);

    PartitioRouterV2.Venue[] venues;
    bytes32[] leaves;
    bytes32 root;

    function setUp() public {
        user = vm.addr(userPk);

        address c0 = AAPL < USDG ? AAPL : USDG;
        address c1 = AAPL < USDG ? USDG : AAPL;
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3,
            0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D, c0, c1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3,
            0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed, c0, c1, 0, 0, address(0)));
        for (uint256 i = 0; i < venues.length; i++)
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));
        root = _pair(leaves[0], leaves[1]);

        router = new PartitioRouterV2(IPoolManager(PM), root);
        entry = new GaslessEntry(IUSDG(USDG), router,
            [KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _legs(uint256 a0, uint256 a1) internal view returns (PartitioRouterV2.Leg[] memory legs) {
        uint256 n = (a0 > 0 ? 1 : 0) + (a1 > 0 ? 1 : 0);
        legs = new PartitioRouterV2.Leg[](n);
        uint256 j;
        if (a0 > 0) { bytes32[] memory p = new bytes32[](1); p[0] = leaves[1];
                      legs[j++] = PartitioRouterV2.Leg(venues[0], p, a0); }
        if (a1 > 0) { bytes32[] memory p = new bytes32[](1); p[0] = leaves[0];
                      legs[j++] = PartitioRouterV2.Leg(venues[1], p, a1); }
    }

    function _order(uint256 amountIn, uint256 maxFee, uint256 minOut, bytes32 salt)
        internal view returns (GaslessEntry.Order memory o)
    {
        GaslessEntry.Output[] memory outs = new GaslessEntry.Output[](1);
        outs[0] = GaslessEntry.Output({
            token: AAPL, weightBps: 10_000, minOut: minOut,
            guard: OracleGuard.Params({feed: AAPL_FEED, stockIsInput: false, maxDevBps: 300})
        });
        o = GaslessEntry.Order({
            owner: user, tokenIn: USDG, amountIn: amountIn, maxFee: maxFee,
            deadline: block.timestamp + 600, salt: salt, outputs: outs
        });
    }

    /// Sign both the order and the EIP-3009 authorisation whose nonce IS the order hash.
    function _auth(GaslessEntry.Order memory o) internal view returns (GaslessEntry.Auth memory a) {
        bytes32 oh = entry.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, oh);

        bytes32 ds = IUSDGDomain(USDG).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(
            RECEIVE_TYPEHASH, o.owner, address(entry), o.amountIn, uint256(0), o.deadline, oh));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, structHash));
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(userPk, digest);

        a = GaslessEntry.Auth({v: v, r: r, s: s, pv: pv, pr: pr, ps: ps,
                               validAfter: 0, validBefore: o.deadline});
    }

    function _route(uint256 a0, uint256 a1) internal view returns (GaslessEntry.Route memory) {
        return GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs(a0, a1)});
    }

    // ------------------------------------------------------------------ tests

    function test_gaslessBuyWithRealUSDG() public {
        uint256 amt = 1000e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(1)));
        GaslessEntry.Auth memory a = _auth(o);

        uint256 relayerBefore = IERC20(USDG).balanceOf(relayer);
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, a, _route((amt - fee) / 2, (amt - fee) / 2), fee);

        console2.log("user AAPL received:", outs[0]);
        assertGt(outs[0], 0, "no AAPL delivered");
        assertEq(IERC20(AAPL).balanceOf(user), outs[0], "AAPL did not reach the user");
        assertEq(IERC20(USDG).balanceOf(relayer) - relayerBefore, fee, "relayer fee wrong");
        // the user never held ETH and never sent a transaction
        assertEq(user.balance, 0, "user should never need ETH");
    }

    /// no funds at rest
    function test_nothingLeftInEither() public {
        uint256 amt = 1000e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(2)));
        vm.prank(relayer);
        entry.fill(o, _auth(o), _route((amt - 1e6) / 2, (amt - 1e6) / 2), 1e6);
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "entry kept USDG");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0, "entry kept AAPL");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router kept USDG");
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "router kept AAPL");
    }

    /// replay: the same order cannot be filled twice
    function test_replayRejected() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt * 2);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(3)));
        GaslessEntry.Auth memory a = _auth(o);
        vm.prank(relayer);
        entry.fill(o, a, _route(amt - 1e6, 0), 1e6);

        bytes32 oh = entry.hashOrder(o);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntry.AlreadyExecuted.selector, oh));
        entry.fill(o, a, _route(amt - 1e6, 0), 1e6);
    }

    /// USDG's own authorization state is the second lock
    function test_usdgAuthorizationConsumed() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(4)));
        bytes32 oh = entry.hashOrder(o);
        assertFalse(IUSDG(USDG).authorizationState(user, oh), "nonce used before the fill");
        vm.prank(relayer);
        entry.fill(o, _auth(o), _route(amt - 1e6, 0), 1e6);
        assertTrue(IUSDG(USDG).authorizationState(user, oh), "USDG did not consume the nonce");
    }

    function test_feeAboveMaxRejected() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 1e6, 0, bytes32(uint256(5)));
        GaslessEntry.Auth memory a = _auth(o);     // hoisted: _auth makes an external call
        GaslessEntry.Route memory r = _route(amt - 2e6, 0);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntry.FeeAboveMax.selector, 2e6, 1e6));
        vm.prank(relayer);
        entry.fill(o, a, r, 2e6);
    }

    function test_minOutEnforced() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        // demand an absurd amount of AAPL
        GaslessEntry.Order memory o = _order(amt, 5e6, 1000e18, bytes32(uint256(6)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = _route(amt - 1e6, 0);
        vm.expectRevert();
        vm.prank(relayer);
        entry.fill(o, a, r, 1e6);
    }

    function test_forgedSignatureRejected() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(7)));
        GaslessEntry.Auth memory a = _auth(o);
        a.v = a.v == 27 ? 28 : 27;               // corrupt the order signature
        vm.prank(relayer);
        vm.expectRevert();
        entry.fill(o, a, _route(amt - 1e6, 0), 1e6);
    }

    function test_unlistedAggregatorRejected() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(8)));
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(0xDEAD), callData: hex"00", aggMinOut: 0, legs: _legs(amt - 1e6, 0)});
        GaslessEntry.Auth memory a = _auth(o);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntry.AggregatorNotAllowed.selector, address(0xDEAD)));
        vm.prank(relayer);
        entry.fill(o, a, r, 1e6);
    }

    /// An allowlisted aggregator whose call reverts must fall back to partitio in the SAME tx.
    function test_failingAggregatorFallsBackInSameTx() public {
        uint256 amt = 500e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(9)));
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: KYBER_ROUTER,
            callData: hex"deadbeef",                 // garbage: the call will revert
            aggMinOut: 0,
            legs: _legs(amt - fee, 0)
        });
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, _auth(o), r, fee);
        console2.log("fallback delivered AAPL:", outs[0]);
        assertGt(outs[0], 0, "fallback did not run");
        assertEq(IERC20(AAPL).balanceOf(user), outs[0]);
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "USDG stranded after fallback");
    }

    /// @notice Slither flags `safeTransferFrom(o.owner, ...)` as "arbitrary from used with
    /// permit". It is safe here only because the order signature is verified BEFORE the pull, so
    /// `o.owner` is not arbitrary — it is the address that signed. This test pins that down: a
    /// victim with a standing allowance, and an order signed by somebody else, must revert. If
    /// anyone ever moves the ECDSA check below `_pullIn`, this fails.
    function test_cannotPullFromAVictimWithAStandingAllowance() public {
        uint256 victimPk = 0xB0B;
        address victim = vm.addr(victimPk);
        uint256 amt = 500e6;
        deal(USDG, victim, amt);
        // the victim has already approved the entry contract from some earlier interaction
        vm.prank(victim);
        IERC20(USDG).approve(address(entry), type(uint256).max);

        // attacker builds an order draining the victim, and signs it with their OWN key
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(99)));
        o.owner = victim;
        bytes32 oh = entry.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(userPk, oh);   // NOT the victim's key
        GaslessEntry.Auth memory a = GaslessEntry.Auth({
            v: v, r: r, s: s2, pv: v, pr: r, ps: s2, validAfter: 0, validBefore: o.deadline});
        GaslessEntry.Route memory rt = _route(amt - 1e6, 0);

        uint256 victimBefore = IERC20(USDG).balanceOf(victim);
        vm.expectRevert(GaslessEntry.BadSignature.selector);
        vm.prank(relayer);
        entry.fill(o, a, rt, 1e6);
        assertEq(IERC20(USDG).balanceOf(victim), victimBefore, "victim lost funds");
    }

    function test_expiredOrderRejected() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _order(amt, 5e6, 0, bytes32(uint256(10)));
        GaslessEntry.Auth memory a = _auth(o);
        vm.warp(o.deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(GaslessEntry.Expired.selector);
        entry.fill(o, a, _route(amt - 1e6, 0), 1e6);
    }
}

interface IUSDGDomain { function DOMAIN_SEPARATOR() external view returns (bytes32); }
