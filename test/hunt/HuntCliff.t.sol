// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "../review/ReviewBase.sol";
import {SkimmingAggregator} from "../review/Mocks.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Where exactly is the cliff? The accepted-aggregator fall-through hands `spendable - spent` to
/// ROUTER.swapExactIn with no try/catch, so the size of the leftover decides whether an otherwise
/// perfect fill settles or reverts.
contract HuntCliff is ReviewBase {
    SkimmingAggregator internal agg;

    function setUp() public {
        agg = new SkimmingAggregator();
        _baseSetUp([address(agg), address(0), address(0), address(0)]);
    }

    function _try(uint256 dust, uint256 salt) internal returns (bool ok, bytes4 sel) {
        uint256 amt = 1000e6;
        uint256 fee = 5e6;
        uint256 spendable = amt - fee;
        uint256 eaten = spendable - dust;

        deal(USDG, user, amt);
        uint256 honest = (_oracleAapl(eaten) * 9_990) / 10_000;
        deal(AAPL, address(agg), honest);

        GaslessEntry.Order memory o = _buyOrder(amt, fee, 0, bytes32(salt));
        GaslessEntry.Auth memory a = _auth(o);
        GaslessEntry.Route memory r = GaslessEntry.Route({
            aggregator: address(agg),
            callData: abi.encodeCall(SkimmingAggregator.swap, (USDG, eaten, AAPL, honest, relayer)),
            aggMinOut: 0,
            legs: _legs1(0, spendable)
        });
        bytes memory err;
        vm.prank(relayer);
        (ok, err) = address(entry).call(abi.encodeCall(GaslessEntry.fill, (o, a, r, fee)));
        if (!ok && err.length >= 4) assembly { sel := mload(add(err, 0x20)) }
    }

    function test_huntCliff_whichLeftoverSizesBrickTheFill() public {
        uint256[8] memory dusts = [uint256(0), 1, 10, 100, 1_000, 10_000, 100_000, 1_000_000];
        for (uint256 i = 0; i < dusts.length; i++) {
            (bool ok, bytes4 sel) = _try(dusts[i], 0xC1F0 + i);
            console2.log("leftover (USDG wei):", dusts[i]);
            console2.log("   settled?", ok);
            if (!ok) console2.logBytes4(sel);
        }
    }
}
