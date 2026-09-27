// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DeployV2} from "../../script/DeployV2.s.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {GaslessEntry} from "../../src/v2/GaslessEntry.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";

/// Exposes the router's OWN leaf and proof arithmetic. Recomputing either in the test would test
/// the test; the claim is that the contract that will be deployed accepts every committed venue.
contract RouterProbe is PartitioRouterV2 {
    constructor(IPoolManager pm, bytes32 root, address[] memory t, address[] memory f)
        PartitioRouterV2(pm, root, t, f) {}

    function accepts(bytes32[] memory proof, Venue memory v) external view returns (bool) {
        return _verify(proof, _leaf(v));
    }
}

/// The deploy, run for real against a fork of mainnet with the exact generated inputs.
contract DeployV2Test is Test {
    DeployV2 internal d;

    function setUp() public {
        d = new DeployV2();
    }

    /// The script deploys, and every immutable reads back equal to its input.
    function test_deployReadsBackEveryImmutable() public {
        DeployV2.Inputs memory i = d.load();
        (PartitioRouterV2 router, GaslessEntry entry) = d.deploy(i);
        d.check(i, router, entry);
    }

    /// Every one of the committed venues proves membership in the root through the router's own
    /// `_verify(_leaf(v))` - the same call `swapExactIn` makes on every leg.
    function test_everyCommittedVenueProvesAgainstTheDeployedRoot() public {
        DeployV2.Inputs memory i = d.load();
        RouterProbe probe = new RouterProbe(IPoolManager(i.poolManager), i.venueRoot, i.stockTokens, i.feeds);
        string memory j = vm.readFile("relayer/venues.json");
        uint256 n = vm.parseJsonUint(j, ".count");
        assertEq(vm.parseJsonBytes32(j, ".root"), i.venueRoot, "relayer/venues.json and deploy inputs disagree");
        for (uint256 k = 0; k < n; k++) {
            PartitioRouterV2.Venue memory v = _venue(j, k);
            bytes32[] memory proof = vm.parseJsonBytes32Array(j, string.concat(".venues[", vm.toString(k), "].proof"));
            assertTrue(probe.accepts(proof, v), string.concat("venue ", vm.toString(k), " does not prove"));
        }
        console2.log("committed venues proven:", n);
    }

    /// Control: the same check REJECTS a venue that differs in one field, so the pass above is not
    /// a verifier that accepts everything.
    function test_aTamperedVenueDoesNotProve() public {
        DeployV2.Inputs memory i = d.load();
        RouterProbe probe = new RouterProbe(IPoolManager(i.poolManager), i.venueRoot, i.stockTokens, i.feeds);
        string memory j = vm.readFile("relayer/venues.json");
        PartitioRouterV2.Venue memory v = _venue(j, 0);
        bytes32[] memory proof = vm.parseJsonBytes32Array(j, ".venues[0].proof");
        assertTrue(probe.accepts(proof, v), "control precondition");
        (v.token0, v.token1) = (v.token1, v.token0);           // the v1 deploy mistake
        assertFalse(probe.accepts(proof, v), "an inverted pair must not prove");
    }

    function _venue(string memory j, uint256 k) internal pure returns (PartitioRouterV2.Venue memory v) {
        string memory p = string.concat(".venues[", vm.toString(k), "]");
        v.kind = PartitioRouterV2.Kind(uint8(vm.parseJsonUint(j, string.concat(p, ".kindNum"))));
        v.target = vm.parseJsonAddress(j, string.concat(p, ".target"));
        v.token0 = vm.parseJsonAddress(j, string.concat(p, ".token0"));
        v.token1 = vm.parseJsonAddress(j, string.concat(p, ".token1"));
        v.fee = uint24(vm.parseJsonUint(j, string.concat(p, ".fee")));
        v.tickSpacing = int24(vm.parseJsonInt(j, string.concat(p, ".tickSpacing")));
        v.hooks = vm.parseJsonAddress(j, string.concat(p, ".hooks"));
    }
}
