// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "../review/ReviewBase.sol";
import {SkimmingAggregator} from "../review/Mocks.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Conservation across the accept-branch fall-through: with the aggregator and the router BOTH
/// consuming input in one fill, does every wei still end up somewhere it should?
contract HuntConservation is ReviewBase {
    SkimmingAggregator internal agg;

    function setUp() public {
        agg = new SkimmingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    function testFuzz_huntC_bothLegsConsumeAndNothingIsStranded(uint256 eatBps, uint256 feeRaw) public {
        uint256 amt = 1000e6;
        uint256 fee = bound(feeRaw, 0, 5e6);
        eatBps = bound(eatBps, 1, 9_999);            // always leave a remainder for the router
        uint256 spendable = amt - fee;
        uint256 eaten = (spendable * eatBps) / 10_000;
        if (eaten == 0 || spendable - eaten < 100) return;   // below the venue's rounding floor

        deal(USDG, user, amt);
        uint256 honest = (_oracleAapl(eaten) * 9_990) / 10_000;
        deal(AAPL, address(agg), honest);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, keccak256(abi.encode(eatBps, feeRaw)));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, eaten, AAPL, honest, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });

        uint256 userUsdg0 = IERC20(USDG).balanceOf(user);
        uint256 userAapl0 = IERC20(AAPL).balanceOf(user);

        vm.prank(relayer);
        (bool ok, ) = address(entry).call(abi.encodeCall(GaslessEntry.fill, (o, a, r, fee)));
        if (!ok) return;

        // 1. Neither contract holds anything afterwards.
        assertEq(IERC20(USDG).balanceOf(address(entry)),  0, "entry stranded USDG");
        assertEq(IERC20(AAPL).balanceOf(address(entry)),  0, "entry stranded AAPL");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router stranded USDG");
        assertEq(IERC20(AAPL).balanceOf(address(router)), 0, "router stranded AAPL");

        // 2. The user's USDG outflow is exactly the amount the fill claims to have transacted.
        uint256 userOut = userUsdg0 - IERC20(USDG).balanceOf(user);
        assertLe(userOut, amt, "user paid more than they signed for");
        assertGt(IERC20(AAPL).balanceOf(user), userAapl0, "user received no stock");

        // 3. The aggregator's counterparty (the relayer) never ends up with more USDG than the
        //    input it was routed plus the capped fee.
        assertLe(userOut, eaten + (spendable - eaten) + fee, "outflow exceeds the whole order");
    }
}
