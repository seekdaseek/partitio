// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {IUSDG} from "../../src/v2/IUSDG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPermitToken {
    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external;
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// Signature-class review: replay, domain separation, field malleability, and the two-signature
/// entry paths. Most of this is clean and is recorded as such. R-12 is the exception.
///
/// R-12  MEDIUM  A user can only have one outstanding permit-funded (stock-selling) order at a
///               time, and the relayer decides which one that is.
contract R11_Signature is ReviewBase {
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        _baseSetUp([KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    // ---------------------------------------------------------------- EIP-712 conformance

    /// Rebuild the digest from the EIP-712 spec by hand - referenced struct types appended in
    /// alphabetical order, dynamic array of structs hashed as the concatenation of its members'
    /// struct hashes - and require it to equal what the contract computes. If these diverge, a
    /// wallet signing the typed data would produce a signature the contract rejects, or worse,
    /// sign something other than what it displayed. They agree.
    function test_clean_eip712DigestMatchesAnIndependentImplementation() public view {
        GaslessEntry.Order memory o = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(0xC0FFEE)));

        bytes32 guardTypehash = keccak256("Guard(address feed,bool stockIsInput,uint256 maxDevBps)");
        bytes32 outputTypehash = keccak256(
            "Output(address token,uint16 weightBps,uint256 minOut,Guard guard)Guard(address feed,bool stockIsInput,uint256 maxDevBps)"
        );
        bytes32 orderTypehash = keccak256(
            "Order(address owner,address tokenIn,uint256 amountIn,uint256 maxFee,uint256 deadline,bytes32 salt,Output[] outputs)Guard(address feed,bool stockIsInput,uint256 maxDevBps)Output(address token,uint16 weightBps,uint256 minOut,Guard guard)"
        );

        bytes32[] memory outH = new bytes32[](o.outputs.length);
        for (uint256 i = 0; i < o.outputs.length; i++) {
            bytes32 gh = keccak256(
                abi.encode(
                    guardTypehash, o.outputs[i].guard.feed, o.outputs[i].guard.stockIsInput,
                    o.outputs[i].guard.maxDevBps
                )
            );
            outH[i] = keccak256(
                abi.encode(outputTypehash, o.outputs[i].token, o.outputs[i].weightBps, o.outputs[i].minOut, gh)
            );
        }
        bytes32 structHash = keccak256(
            abi.encode(
                orderTypehash, o.owner, o.tokenIn, o.amountIn, o.maxFee, o.deadline, o.salt,
                keccak256(abi.encodePacked(outH))
            )
        );
        bytes32 ds = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("partitio"), keccak256("2"), block.chainid, address(entry)
            )
        );
        assertEq(entry.hashOrder(o), keccak256(abi.encodePacked("\x19\x01", ds, structHash)));
    }

    /// The domain binds chainId, so the same order signed here is worthless on another chain.
    function test_clean_orderHashIsChainBound() public {
        GaslessEntry.Order memory o = _buyOrder(1000e6, 5e6, 0, bytes32(uint256(1)));
        bytes32 here = entry.hashOrder(o);
        vm.chainId(1);
        assertTrue(entry.hashOrder(o) != here, "hash survived a chain change");
        vm.chainId(4663);
        assertEq(entry.hashOrder(o), here, "hash did not come back");
    }

    /// The domain binds verifyingContract, so a second deployment cannot consume the signature.
    function test_clean_orderHashIsContractBound() public {
        GaslessEntry.Order memory o = _buyOrder(1000e6, 5e6, 0, bytes32(uint256(2)));
        GaslessEntry other = new GaslessEntry(IUSDG(USDG), router, [KYBER_ROUTER, address(0), address(0), address(0)]);
        assertTrue(other.hashOrder(o) != entry.hashOrder(o), "two deployments share an order hash");
    }

    /// Every signed field moves the hash: no two distinct orders collide on the fields the user
    /// actually commits to.
    function test_clean_everySignedFieldIsBinding() public view {
        GaslessEntry.Order memory base = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        bytes32 h = entry.hashOrder(base);

        GaslessEntry.Order memory m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.owner = address(0xDEAD);      assertTrue(entry.hashOrder(m) != h, "owner");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.tokenIn = AAPL;               assertTrue(entry.hashOrder(m) != h, "tokenIn");
        m = _buyOrder(1000e6 + 1, 5e6, 1e18, bytes32(uint256(3)));
                                        assertTrue(entry.hashOrder(m) != h, "amountIn");
        m = _buyOrder(1000e6, 5e6 + 1, 1e18, bytes32(uint256(3)));
                                        assertTrue(entry.hashOrder(m) != h, "maxFee");
        m = _buyOrder(1000e6, 5e6, 1e18 + 1, bytes32(uint256(3)));
                                        assertTrue(entry.hashOrder(m) != h, "minOut");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(4)));
                                        assertTrue(entry.hashOrder(m) != h, "salt");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.deadline += 1;                assertTrue(entry.hashOrder(m) != h, "deadline");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.outputs[0].token = AMZN;      assertTrue(entry.hashOrder(m) != h, "output token");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.outputs[0].weightBps = 9_999; assertTrue(entry.hashOrder(m) != h, "weightBps");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.outputs[0].guard.feed = AMZN_FEED;      assertTrue(entry.hashOrder(m) != h, "guard.feed");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.outputs[0].guard.stockIsInput = true;   assertTrue(entry.hashOrder(m) != h, "guard.stockIsInput");
        m = _buyOrder(1000e6, 5e6, 1e18, bytes32(uint256(3)));
        m.outputs[0].guard.maxDevBps = 301;       assertTrue(entry.hashOrder(m) != h, "guard.maxDevBps");
    }

    /// A malleated (s, v) pair is rejected outright by OpenZeppelin's ECDSA, so it cannot even be
    /// used to burn an order slot with a different-looking signature.
    function test_clean_malleableSignatureRejected() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(5)));
        GaslessEntry.Auth memory a = _auth(o);

        a.s = bytes32(SECP256K1N - uint256(a.s));
        a.v = a.v == 27 ? 28 : 27;
        GaslessEntry.Route memory r = _routerRoute(amt - 1e6);
        vm.prank(relayer);
        vm.expectRevert(); // ECDSAInvalidSignatureS
        entry.fill(o, a, r, 1e6);
    }

    /// The EIP-3009 authorization is payee-bound and nonce-bound to the order hash, so nobody but
    /// this contract can spend it, and it cannot fund any other order.
    function test_clean_eip3009AuthorizationIsPayeeAndOrderBound() public {
        uint256 amt = 500e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(6)));
        GaslessEntry.Auth memory a = _auth(o);
        bytes32 oh = entry.hashOrder(o);

        // an outsider replaying the authorization directly against USDG
        vm.prank(attacker);
        vm.expectRevert();
        IUSDG(USDG).receiveWithAuthorization(user, address(entry), amt, 0, o.deadline, oh, a.pv, a.pr, a.ps);

        // a second GaslessEntry cannot use it either: the order hash embeds the verifying contract
        GaslessEntry other = new GaslessEntry(IUSDG(USDG), router, [KYBER_ROUTER, address(0), address(0), address(0)]);
        GaslessEntry.Route memory r = _routerRoute(amt - 1e6);
        vm.prank(relayer);
        vm.expectRevert();
        other.fill(o, a, r, 1e6);

        assertFalse(IUSDG(USDG).authorizationState(user, oh), "nonce must still be unused");
    }

    // ---------------------------------------------------------------- R-12 permit path

    function _sellOrder(uint256 amountIn, bytes32 salt) internal view returns (GaslessEntry.Order memory o) {
        GaslessEntry.Output[] memory outs = new GaslessEntry.Output[](1);
        outs[0] = GaslessEntry.Output({
            token: USDG,
            weightBps: 10_000,
            minOut: 0,
            guard: OracleGuard.Params({feed: AAPL_FEED, stockIsInput: true, maxDevBps: 500})
        });
        o = GaslessEntry.Order({
            owner: user, tokenIn: AAPL, amountIn: amountIn, maxFee: 1e15,
            deadline: block.timestamp + 600, salt: salt, outputs: outs
        });
    }

    function _sellAuth(GaslessEntry.Order memory o, uint256 permitNonce)
        internal view returns (GaslessEntry.Auth memory a)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, entry.hashOrder(o));
        bytes32 sh = keccak256(
            abi.encode(PERMIT_TYPEHASH, o.owner, address(entry), o.amountIn, permitNonce, o.deadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IPermitToken(AAPL).DOMAIN_SEPARATOR(), sh));
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(userPk, digest);
        a = GaslessEntry.Auth({v: v, r: r, s: s, pv: pv, pr: pr, ps: ps, validAfter: 0, validBefore: o.deadline});
    }

    /// Control: a single permit-funded sell order fills.
    function test_R12_control_oneSellOrderFills() public {
        deal(AAPL, user, 2e18);
        uint256 n = IPermitToken(AAPL).nonces(user);
        GaslessEntry.Order memory o = _sellOrder(1e18, bytes32(uint256(20)));
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs1(0, 1e18 - 1e15)});
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o, _sellAuth(o, n), r, 1e15);
        assertGt(outs[0], 0, "sell should fill");
    }

    /// Two outstanding sell orders. ERC20Permit nonces are strictly sequential, so whichever order
    /// the relayer picks second is unfillable: its permit reverts on the nonce, the catch swallows
    /// that, and `transferFrom` then fails on a zero allowance. The user must re-sign.
    function test_R12_secondPermitOrderIsBrickedByFillOrder() public {
        deal(AAPL, user, 4e18);
        uint256 n = IPermitToken(AAPL).nonces(user);

        GaslessEntry.Order memory oA = _sellOrder(1e18, bytes32(uint256(21)));
        GaslessEntry.Order memory oB = _sellOrder(1e18, bytes32(uint256(22)));
        GaslessEntry.Auth memory aA = _sellAuth(oA, n);       // permit nonce n
        GaslessEntry.Auth memory aB = _sellAuth(oB, n + 1);   // permit nonce n+1
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: address(0), callData: "", aggMinOut: 0, legs: _legs1(0, 1e18 - 1e15)});

        // the relayer fills B first - a free choice, nothing in either order forbids it
        vm.prank(relayer);
        vm.expectRevert(); // ERC20InsufficientAllowance after the swallowed permit failure
        entry.fill(oB, aB, r, 1e15);

        // and A still works, which pins the cause on ordering rather than on order B being invalid
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(oA, aA, r, 1e15);
        assertGt(outs[0], 0, "order A fills once it is first");

        // now B fills too, because its nonce finally came up
        vm.prank(relayer);
        uint256[] memory outsB = entry.fill(oB, aB, r, 1e15);
        assertGt(outsB[0], 0, "B fills second");
    }
}
