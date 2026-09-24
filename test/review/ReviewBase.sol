// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IUSDG} from "../../src/v2/IUSDG.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUSDGDomain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Shared fork fixture for the independent review's tests. Mirrors test/GaslessEntry.t.sol
/// so a finding cannot be waved away as "your harness is different".
abstract contract ReviewBase is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant AMZN_FEED = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C;
    address constant KYBER_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    // v3 pools quoting each stock against USDG (script/recon/venues.json, active=true)
    address constant AAPL_POOL_A = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D;
    address constant AAPL_POOL_B = 0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed;
    address constant AMZN_POOL = 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef;

    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 internal userPk = 0xA11CE;
    address internal user;
    address internal relayer = address(0xBEEF);
    address internal attacker = address(0xACAB);

    PartitioRouterV2 internal router;
    GaslessEntry internal entry;

    PartitioRouterV2.Venue[] internal venues;
    bytes32[] internal leaves;
    bytes32 internal root;

    function _baseSetUp(address[4] memory aggs) internal {
        user = vm.addr(userPk);
        _buildVenues();
        router = new PartitioRouterV2(IPoolManager(PM), root, _stockTokens(), _feeds());
        entry = new GaslessEntry(IUSDG(USDG), router, aggs);
    }

    function _stockTokens() internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = AAPL;
        t[1] = AMZN;
    }

    function _feeds() internal pure returns (address[] memory f) {
        f = new address[](2);
        f[0] = AAPL_FEED;
        f[1] = AMZN_FEED;
    }

    /// 4 leaves: AAPL pool A, AAPL pool B, AMZN pool, and a placeholder v4 key.
    function _buildVenues() internal {
        (address a0, address a1) = AAPL < USDG ? (AAPL, USDG) : (USDG, AAPL);
        (address z0, address z1) = AMZN < USDG ? (AMZN, USDG) : (USDG, AMZN);
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, AAPL_POOL_A, a0, a1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, AAPL_POOL_B, a0, a1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V3, AMZN_POOL, z0, z1, 0, 0, address(0)));
        venues.push(PartitioRouterV2.Venue(PartitioRouterV2.Kind.V4, address(0), a0, a1, 3000, 60, address(0)));
        for (uint256 i = 0; i < venues.length; i++) {
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(venues[i])))));
        }
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
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

    function _leg(uint256 venueIdx, uint256 amt) internal view returns (PartitioRouterV2.Leg memory) {
        return PartitioRouterV2.Leg(venues[venueIdx], _proof(venueIdx), amt);
    }

    function _legs1(uint256 venueIdx, uint256 amt)
        internal
        view
        returns (PartitioRouterV2.Leg[] memory legs)
    {
        legs = new PartitioRouterV2.Leg[](1);
        legs[0] = _leg(venueIdx, amt);
    }

    // ------------------------------------------------------------------ orders

    function _buyOrder(uint256 amountIn, uint256 maxFeeUsdg, uint256 minOut, bytes32 salt)
        internal
        view
        returns (GaslessEntry.Order memory o)
    {
        o = GaslessEntry.Order({
            owner: user,
            tokenIn: USDG,
            amountIn: amountIn,
            tokenOut: AAPL,
            minOut: minOut,
            maxFeeUsdg: maxFeeUsdg,
            deadline: block.timestamp + 600,
            salt: salt,
            guard: OracleGuard.Params({maxDevBps: 300})
        });
    }

    function _auth(GaslessEntry.Order memory o) internal view returns (GaslessEntry.Auth memory a) {
        bytes32 oh = entry.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, oh);
        bytes32 ds = IUSDGDomain(USDG).DOMAIN_SEPARATOR();
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, o.owner, address(entry), o.amountIn, uint256(0), o.deadline, oh));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, structHash));
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(userPk, digest);
        a = GaslessEntry.Auth({v: v, r: r, s: s, pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline});
    }

    /// @dev Legs must sum to exactly the spendable amount since R-04, so routes are built from it.
    function _routerRoute(uint256 spendable) internal view returns (GaslessEntry.Route memory) {
        return GaslessEntry.Route({
            aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs1(0, spendable)
        });
    }

    /// What the Chainlink feed says `amountIn` USDG is worth in AAPL, ignoring any band.
    function _oracleAapl(uint256 usdgIn) internal view returns (uint256) {
        (, int256 answer,,,) = IAgg(AAPL_FEED).latestRoundData();
        uint8 fd = IAgg(AAPL_FEED).decimals();
        return (usdgIn * (10 ** 18) * (10 ** fd)) / ((10 ** 6) * uint256(answer));
    }
}

interface IAgg {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
