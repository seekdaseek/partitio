// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PartitioRouterV2} from "../src/v2/PartitioRouterV2.sol";
import {GaslessEntry} from "../src/v2/GaslessEntry.sol";
import {IUSDG} from "../src/v2/IUSDG.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";

/// @notice Deploys PartitioRouterV2 and GaslessEntry from deploy/v2-inputs.json, then reads every
/// immutable back and refuses to report success unless each one matches its input.
///
/// Nothing here is typed by hand. The venue root, the token->feed arrays and the aggregator
/// allowlist are produced and verified on-chain by script/predeploy-bindings.mjs and
/// script/deploy-inputs.mjs; this script only carries them into the constructors. Both contracts
/// are ownerless, so a wrong constructor argument is a redeploy - the check below is the last
/// moment it can be caught for the price of a revert instead of a deployment.
///
/// Fork dry run:  forge script script/DeployV2.s.sol --fork-url <rpc>
/// Mainnet:       forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast --private-key ...
contract DeployV2 is Script {
    struct Inputs {
        uint256 chainId;
        address poolManager;
        address usdg;
        bytes32 venueRoot;
        address[] stockTokens;
        address[] feeds;
        address[4] aggregators;
    }

    string internal constant INPUTS = "deploy/v2-inputs.json";

    function load() public view returns (Inputs memory i) {
        string memory j = vm.readFile(INPUTS);
        i.chainId = vm.parseJsonUint(j, ".chainId");
        i.poolManager = vm.parseJsonAddress(j, ".poolManager");
        i.usdg = vm.parseJsonAddress(j, ".usdg");
        i.venueRoot = vm.parseJsonBytes32(j, ".venueRoot");
        i.stockTokens = vm.parseJsonAddressArray(j, ".stockTokens");
        i.feeds = vm.parseJsonAddressArray(j, ".feeds");
        address[] memory a = vm.parseJsonAddressArray(j, ".aggregators");
        require(a.length == 4, "aggregators must be exactly 4 slots");
        for (uint256 k = 0; k < 4; k++) i.aggregators[k] = a[k];
        require(i.stockTokens.length == i.feeds.length && i.stockTokens.length > 0, "feed map shape");
        require(i.venueRoot != bytes32(0), "empty venue root");
    }

    function deploy(Inputs memory i) public returns (PartitioRouterV2 router, GaslessEntry entry) {
        router = new PartitioRouterV2(IPoolManager(i.poolManager), i.venueRoot, i.stockTokens, i.feeds);
        entry = new GaslessEntry(IUSDG(i.usdg), router, i.aggregators);
    }

    /// Every immutable, read back from the deployed code and compared with the input it came from.
    function check(Inputs memory i, PartitioRouterV2 router, GaslessEntry entry) public view {
        require(block.chainid == i.chainId, "wrong chain");
        require(address(router.poolManager()) == i.poolManager, "router.poolManager");
        require(router.VENUE_ROOT() == i.venueRoot, "router.VENUE_ROOT");
        for (uint256 k = 0; k < i.stockTokens.length; k++) {
            require(router.feedOf(i.stockTokens[k]) == i.feeds[k], "router.feedOf");
        }
        require(address(entry.USDG()) == i.usdg, "entry.USDG");
        require(address(entry.ROUTER()) == address(router), "entry.ROUTER");
        uint256 allowed;
        for (uint256 k = 0; k < 4; k++) {
            if (i.aggregators[k] == address(0)) continue;
            require(entry.isAllowedAggregator(i.aggregators[k]), "entry.isAllowedAggregator");
            allowed++;
        }
        require(!entry.isAllowedAggregator(address(0)), "address(0) must never be allowed");
        require(entry.MAX_FEE_BPS() == 50, "entry.MAX_FEE_BPS");
        require(address(router).code.length > 0 && address(entry).code.length > 0, "no code");
        console2.log("router         ", address(router));
        console2.log("gasless entry  ", address(entry));
        console2.log("venue root      verified");
        console2.log("feeds bound    ", i.stockTokens.length);
        console2.log("aggregators    ", allowed);
    }

    function run() external returns (PartitioRouterV2 router, GaslessEntry entry) {
        Inputs memory i = load();
        vm.startBroadcast();
        (router, entry) = deploy(i);
        vm.stopBroadcast();
        check(i, router, entry);
    }
}
