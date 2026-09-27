// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// R-01 (was CRITICAL) — FIXED. Positive tests.
///
/// `fill` used to end each output with `if (token.balanceOf(this) != 0) revert DustLeftBehind(...)`,
/// which assumed the contract's balance of an output token was always exactly what the fill had
/// just produced. An ERC20 balance can be raised by anyone, and GaslessEntry has no owner, no
/// sweep and no rescue, so one wei bricked it permanently for that token.
///
/// The check is gone. Every amount is now a bracketed balance delta, so a pre-existing balance is
/// simply not this order's and is not counted, forwarded or tripped over. These tests assert that
/// donations of both the output token and the input token are inert.
contract R01_DustDoS is ReviewBase {
    function setUp() public {
        _baseSetUp([KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    /// The exact griefing transaction that used to be fatal. It is now inert.
    function test_R01_oneWeiOfAaplNoLongerBricksAnything() public {
        // 1. Anyone sends one wei of AAPL to the entry contract. No approval, no privilege.
        deal(AAPL, attacker, 1);
        vm.prank(attacker);
        IERC20(AAPL).transfer(address(entry), 1);
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 1, "griefing transfer did not land");

        // 2. Orders still fill, for every user, at every size.
        uint256 amt = 1000e6;
        uint256 fee = 1e6;
        for (uint256 i = 0; i < 3; i++) {
            deal(USDG, user, amt);
            GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(100 + i)));
            uint256 userBefore = IERC20(AAPL).balanceOf(user);
            GaslessEntry.Auth memory auth39 = _auth(o);
            vm.prank(relayer);
            uint256 got = entry.fill(o, auth39, _routerRoute(amt - fee), fee);
            assertGt(got, 0, "fill blocked by the donation");
            assertEq(IERC20(AAPL).balanceOf(user) - userBefore, got, "user did not receive the fill");
        }

        // 3. The donated wei is untouched: it was never this order's, so it is neither counted as
        //    output nor handed to a signer who did not pay for it.
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 1, "the attacker's wei moved");
    }

    /// The aggregator branch is delta-accounted too, so the donation does not inflate `got` there.
    function test_R01_donationDoesNotInflateTheAggregatorBranch() public {
        deal(AAPL, attacker, 5e18);
        vm.prank(attacker);
        IERC20(AAPL).transfer(address(entry), 5e18);

        uint256 amt = 500e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(3)));
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: KYBER_ROUTER, callData: hex"deadbeef", aggMinOut: 0, legs: _legs1(0, amt - fee)
        });
        GaslessEntry.Auth memory auth64 = _auth(o);
        vm.prank(relayer);
        uint256 got = entry.fill(o, auth64, r, fee);

        // got is what the fallback actually bought, not 5 AAPL of somebody else's donation
        assertGt(got, 0, "fallback did not run");
        assertLt(got, 5e18, "donation was counted as output");
        assertEq(IERC20(AAPL).balanceOf(user), got, "user got exactly the measured delta");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 5e18, "donation should still be sitting there");
    }

    /// A donated *input* token must not be swept to whoever signs next. The refund is a delta
    /// against a snapshot taken before this order pulled its funds in.
    function test_R01_donatedInputIsNotSweptToTheNextSigner() public {
        deal(USDG, attacker, 250e6);
        vm.prank(attacker);
        IERC20(USDG).transfer(address(entry), 250e6);

        uint256 amt = 500e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);
        uint256 userUsdgBefore = IERC20(USDG).balanceOf(user);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(4)));
        GaslessEntry.Auth memory auth87 = _auth(o);
        vm.prank(relayer);
        entry.fill(o, auth87, _routerRoute(amt - fee), fee);

        // the user spent exactly amt and was handed none of the attacker's 250 USDG
        assertEq(userUsdgBefore - IERC20(USDG).balanceOf(user), amt, "user's USDG delta wrong");
        assertEq(IERC20(USDG).balanceOf(address(entry)), 250e6, "the donation was swept out");
    }

    /// The error itself is gone from the ABI.
    function test_R01_dustLeftBehindSelectorIsNotInTheBytecode() public view {
        bytes4 sel = bytes4(keccak256("DustLeftBehind(address,uint256)"));
        bytes memory code = address(entry).code;
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                revert("DustLeftBehind is still reachable");
            }
        }
    }
}
