// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PartitioProps} from "./PartitioProps.sol";

/// @notice A property that is never exercised is vacuously true. The audit warned that the fuzz
/// harness only ever built buys, which is exactly where the fee-denomination bug was invisible —
/// so a sell handler that silently reverts on every call would be just as blind as no handler.
/// This pins that the handlers actually reach a successful fill.
contract HarnessReachability is Test {
    PartitioProps props;

    function setUp() public {
        props = new PartitioProps();
    }

    function test_buyHandlerReachesASuccessfulFill() public {
        for (uint32 i = 1; i <= 20; i++) {
            props.h_fill(i * 1_000_000, 20, 5_000, 300, 5_000, 0);
        }
        console2.log("fills:", props.fills());
        assertGt(props.fills(), 0, "no buy ever filled - every buy property is vacuous");
    }

    function test_sellHandlerReachesASuccessfulFill() public {
        for (uint32 i = 1; i <= 20; i++) {
            props.h_fillSell(i * 1_000_000, 20, 5_000, 300, 0);
        }
        console2.log("sellFills:", props.sellFills());
        assertGt(props.sellFills(), 0, "no sell ever filled - the fee-cap property is vacuous");
    }

    /// Mode 3 is the honest aggregator route. Modes 1 and 2 are skimming routes that SHOULD
    /// revert on the oracle floor, so a run that only ever tries those proves nothing.
    function test_aggregatorBranchIsReached() public {
        for (uint32 i = 1; i <= 20; i++) {
            props.h_fill(i * 1_000_000, 20, 1_000, 500, 5_000, 3);
        }
        console2.log("aggFills (honest route):", props.aggFills());
        assertGt(props.aggFills(), 0, "the aggregator branch was never taken");
    }

    /// And the skimming routes must NOT complete - that is the floor doing its job.
    function test_skimmingAggregatorRoutesNeverComplete() public {
        uint256 before = props.aggFills();
        for (uint32 i = 1; i <= 20; i++) {
            props.h_fill(i * 1_000_000, 20, 1_000, 500, 5_000, 1);
            props.h_fill(i * 1_000_000, 20, 1_000, 500, 5_000, 2);
        }
        console2.log("aggFills after 40 skimming attempts:", props.aggFills() - before);
        assertEq(props.aggFills(), before, "a skimming aggregator route completed a fill");
        assertFalse(props.aggBelowOracleFloor(), "floor breached");
    }
}
