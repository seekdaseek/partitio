// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {GaslessEntry} from "../src/v2/GaslessEntry.sol";
import {PartitioRouterV2} from "../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../src/v2/OracleGuard.sol";
import {IUSDG, IERC20Permit} from "../src/v2/IUSDG.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDomain { function DOMAIN_SEPARATOR() external view returns (bytes32); }

/// @notice A stand-in aggregator that is allowlisted but delivers LESS than partitio would.
/// It is not hostile — it is stale, which is the realistic failure and the one the fallback exists
/// for. It keeps most of the input and returns a token trickle.
contract UnderDeliveringAggregator {
    address public immutable tokenIn;
    address public immutable tokenOut;
    uint256 public immutable payout;

    constructor(address _in, address _out, uint256 _payout) {
        tokenIn = _in; tokenOut = _out; payout = _payout;
    }

    /// A real aggregator whose quote has gone stale fills what it can and hands the rest back.
    /// It does not eat the whole input — that would be a hostile contract, which is covered
    /// separately by the allowlist. Here we consume a tenth and return the remainder, so the
    /// fallback has something to work with, exactly as it would on chain.
    function swap(uint256 amount) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amount);
        uint256 consumed = amount / 10;
        IERC20(tokenIn).transfer(msg.sender, amount - consumed);
        IERC20(tokenOut).transfer(msg.sender, payout);
    }
}

contract GaslessSellTest is Test {
    GaslessEntry entry;
    PartitioRouterV2 router;

    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 userPk = 0xA11CE;
    address user;
    address relayer = address(0xBEEF);
    address frontRunner = address(0xF00D);

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
        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = AAPL;
        fds[0] = AAPL_FEED;
        router = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
        entry = new GaslessEntry(IUSDG(USDG), router, [address(0), address(0), address(0), address(0)]);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _legs(uint256 a0) internal view returns (PartitioRouterV2.Leg[] memory legs) {
        legs = new PartitioRouterV2.Leg[](1);
        bytes32[] memory p = new bytes32[](1); p[0] = leaves[1];
        legs[0] = PartitioRouterV2.Leg(venues[0], p, a0);
    }

    /// sell order: AAPL in, USDG out
    function _sellOrder(uint256 amountIn, uint256 maxFee, uint256 minOut, bytes32 salt)
        internal view returns (GaslessEntry.Order memory o)
    {
        // The contract refuses minOut == 0 outright now (it was the root of the sliver
        // extraction), so a test that means "effectively no floor" says one wei.
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

    function _route(uint256 a0) internal view returns (GaslessEntry.Route memory) {
        return GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs(a0)});
    }

    // ---------------------------------------------------------------- tests

    /// @notice Gasless SELL. The user signs a permit and an order and never holds ETH.
    /// The fee is taken out of the USDG OUTPUT, and minOut is checked against the NET amount.
    function test_gaslessSellViaPermit() public {
        uint256 amt = 3e18;
        uint256 fee = 1e6;             // 1 USDG
        deal(AAPL, user, amt);
        GaslessEntry.Order memory o = _sellOrder(amt, 5e6, 0, bytes32(uint256(20)));
        GaslessEntry.Auth memory a = _sellAuth(o);

        uint256 relayerBefore = IERC20(USDG).balanceOf(relayer);
        vm.prank(relayer);
        uint256 outs0 = entry.fill(o, a, _route(amt), fee);

        console2.log("net USDG to user:", outs0);
        assertGt(outs0, 0, "no USDG delivered");
        assertEq(IERC20(USDG).balanceOf(user), outs0, "user did not receive the net amount");
        assertEq(IERC20(USDG).balanceOf(relayer) - relayerBefore, fee, "fee not paid in USDG");
        assertEq(user.balance, 0, "user needed ETH");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0);
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0);
    }

    /// @notice minOut on a sell is enforced against the NET, so a fee cannot be used to push the
    /// user below the floor they signed for.
    function test_sellMinOutIsCheckedNetOfFee() public {
        uint256 amt = 3e18;
        deal(AAPL, user, amt);
        // find the gross first
        uint256 snap = vm.snapshotState();
        GaslessEntry.Order memory probe = _sellOrder(amt, 5e6, 0, bytes32(uint256(21)));
        vm.prank(relayer);
        uint256 gross = entry.fill(probe, _sellAuth(probe), _route(amt), 0);
        vm.revertToState(snap);

        // now demand exactly the gross while a fee is charged: net < minOut, must revert
        deal(AAPL, user, amt);
        GaslessEntry.Order memory o = _sellOrder(amt, 5e6, gross, bytes32(uint256(22)));
        GaslessEntry.Auth memory a = _sellAuth(o);
        GaslessEntry.Route memory r = _route(amt);
        vm.expectPartialRevert(GaslessEntry.OutputBelowMin.selector);
        vm.prank(relayer);
        entry.fill(o, a, r, 1e6);
    }

    /// @notice A front-runner submits the user's permit first. The permit inside fill() then
    /// reverts, and the order must still execute on the allowance that now exists.
    function test_permitFrontRunDoesNotBrickTheOrder() public {
        uint256 amt = 3e18;
        deal(AAPL, user, amt);
        GaslessEntry.Order memory o = _sellOrder(amt, 5e6, 0, bytes32(uint256(23)));
        GaslessEntry.Auth memory a = _sellAuth(o);

        // the griefer replays the permit before the relayer gets there
        vm.prank(frontRunner);
        IERC20Permit(AAPL).permit(o.owner, address(entry), o.amountIn, o.deadline, a.pv, a.pr, a.ps);
        assertEq(IERC20(AAPL).allowance(user, address(entry)), amt, "allowance not set by the front-run");

        vm.prank(relayer);
        uint256 outs0 = entry.fill(o, a, _route(amt), 1e6);
        console2.log("filled after front-run, net USDG:", outs0);
        assertGt(outs0, 0, "front-run bricked the order");
    }
}

/// @notice The aggregator fallback, with the realistic failure: a STALE route that still works but
/// delivers less than partitio would. It returns the unused input, as a real aggregator does when
/// its quote no longer holds.
contract AggregatorFallbackTest is Test {
    address constant PM   = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    GaslessEntry entry;
    PartitioRouterV2 router;
    UnderDeliveringAggregator agg;

    uint256 userPk = 0xA11CE;
    address user;
    address relayer = address(0xBEEF);
    PartitioRouterV2.Venue[] venues;
    bytes32[] leaves;
    bytes32 root;

    bytes32 constant RECEIVE_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

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
        bytes32 a0 = leaves[0]; bytes32 a1 = leaves[1];
        root = a0 <= a1 ? keccak256(abi.encode(a0, a1)) : keccak256(abi.encode(a1, a0));

        address[] memory toks = new address[](1);
        address[] memory fds = new address[](1);
        toks[0] = AAPL;
        fds[0] = AAPL_FEED;
        router = new PartitioRouterV2(IPoolManager(PM), root, toks, fds);
        // a stale route: hands back 0.5 AAPL for whatever it is given, and returns the rest
        agg = new UnderDeliveringAggregator(USDG, AAPL, 0.5e18);
        deal(AAPL, address(agg), 10e18);
        entry = new GaslessEntry(IUSDG(USDG), router, [address(agg), address(0), address(0), address(0)]);
    }

    function test_underDeliveringAggregatorFallsBackToPartitio() public {
        uint256 amt = 1000e6;
        deal(USDG, user, amt);

        GaslessEntry.Order memory o = GaslessEntry.Order({
            owner: user, tokenIn: USDG, amountIn: amt, tokenOut: AAPL, minOut: 1,
            maxFeeUsdg: 5e6, deadline: block.timestamp + 600, salt: bytes32(uint256(30)),
            guard: OracleGuard.Params({maxDevBps: 300, maxFeedAge: 120 hours})});

        bytes32 oh = entry.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, oh);
        bytes32 sh = keccak256(abi.encode(RECEIVE_TYPEHASH, o.owner, address(entry), o.amountIn,
            uint256(0), o.deadline, oh));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IDomain(USDG).DOMAIN_SEPARATOR(), sh));
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(userPk, digest);

        PartitioRouterV2.Leg[] memory legs = new PartitioRouterV2.Leg[](1);
        bytes32[] memory proof = new bytes32[](1); proof[0] = leaves[1];
        legs[0] = PartitioRouterV2.Leg(venues[0], proof, amt - 1e6);

        GaslessEntry.Route memory route = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeWithSelector(UnderDeliveringAggregator.swap.selector, amt - 1e6),
            aggMinOut: 2.9e18,               // what partitio would give; the stale route gives 0.5
            legs: legs
        });

        vm.prank(relayer);
        uint256 got0 = entry.fill(o, GaslessEntry.Auth({v: v, r: r, s: s,
            pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline}), route, 1e6);

        console2.log("delivered:", got0);
        // the stale route paid 0.5 AAPL; partitio's fallback must beat that by a wide margin
        assertGt(got0, 2.5e18, "fallback did not run - user got the stale route's price");
        assertEq(IERC20(AAPL).balanceOf(user), got0);
        assertEq(IERC20(USDG).balanceOf(address(entry)), 0, "USDG stranded");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 0, "AAPL stranded");
    }
}
