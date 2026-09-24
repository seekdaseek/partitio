// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReviewBase, console2} from "./ReviewBase.sol";
import {PartitioRouterV2} from "../../src/v2/PartitioRouterV2.sol";
import {OracleGuard} from "../../src/v2/OracleGuard.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// R-09 (was MEDIUM) and `guard-direction-unbound` — FIXED by removal.
///
/// `OracleGuard.Params` used to carry `feed` and `stockIsInput`, both caller-supplied and both
/// unchecked. Pricing a $338 stock against a $246 feed cut the floor by 27%; inverting the
/// direction collapsed it by four orders of magnitude. Neither is expressible now: the router
/// reads the feed off an immutable constructor map and derives the direction from which side of
/// the pair the mapped stock token is on.
///
/// A MAP RATHER THAN A SECOND MERKLE ROOT. The property needed is ONE feed per token, which a
/// mapping enforces structurally and a Merkle multiset cannot — leaves (AAPL, feedA) and
/// (AAPL, feedB) would both verify, and whoever supplies the proof picks. That is not
/// hypothetical: six tickers on 4663 (AAPL, GOOGL, NVDA, QQQ, SPY, TSLA) have a second live
/// aggregator, and the recon table that chose between them did so by "first Morpho market per
/// ticker wins", a rule that already miswired CRWV once.
contract R09_FeedBinding is ReviewBase {
    function setUp() public {
        _baseSetUp([KYBER_ROUTER, address(0), address(0), address(0)]);
    }

    /// The binding is public and checkable with one call per token — the point of preferring a map
    /// to an opaque 32-byte root in an ownerless contract.
    function test_R09_feedBindingIsPublicAndCorrect() public view {
        assertEq(router.feedOf(AAPL), AAPL_FEED, "AAPL feed");
        assertEq(router.feedOf(AMZN), AMZN_FEED, "AMZN feed");
        assertEq(router.feedOf(USDG), address(0), "USDG is not a stock");
    }

    /// Direction is derived from the pair, not signed. Both ways round, from one binding.
    function test_R09_directionIsDerivedFromThePair() public view {
        (address f1, bool stockIsInput1) = router.feedFor(AAPL, USDG);
        assertEq(f1, AAPL_FEED);
        assertTrue(stockIsInput1, "selling AAPL: the stock is the input");

        (address f2, bool stockIsInput2) = router.feedFor(USDG, AAPL);
        assertEq(f2, AAPL_FEED);
        assertFalse(stockIsInput2, "buying AAPL: the stock is the output");
    }

    /// A pair with no mapped side has no reference price. Refused rather than guessed.
    function test_R09_unmappedPairIsRefused() public {
        address weth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        vm.expectRevert(abi.encodeWithSelector(PartitioRouterV2.NoFeedForPair.selector, weth, USDG));
        router.feedFor(weth, USDG);
    }

    /// A stock/stock pair has TWO reference prices, so the guard's direction would be a coin flip.
    /// Also refused.
    function test_R09_stockToStockPairIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(PartitioRouterV2.AmbiguousPair.selector, AAPL, AMZN));
        router.feedFor(AAPL, AMZN);
    }

    /// The old attack — price AAPL against the cheaper AMZN feed — cannot be expressed. A swap
    /// names only tokens; the feed follows from them.
    function test_R09_cannotPriceOneStockAgainstAnothersFeed() public {
        uint256 amt = 10e18;
        deal(AAPL, address(this), amt);
        IERC20(AAPL).approve(address(router), amt);

        // There is no argument that could select AMZN_FEED for an AAPL trade. The only handle the
        // caller has is the band, and the floor it produces is computed from AAPL's own feed.
        (address feed,) = router.feedFor(AAPL, USDG);
        assertEq(feed, AAPL_FEED, "the trade's tokens fix the feed");
        assertTrue(feed != AMZN_FEED, "and it is not substitutable");
    }

    /// The constructor refuses a malformed map, so a deployment cannot quietly bind two feeds to
    /// one token or bind a zero address.
    function test_R09_constructorRejectsABadMap() public {
        address[] memory toks = new address[](2);
        address[] memory fds = new address[](2);
        toks[0] = AAPL; fds[0] = AAPL_FEED;
        toks[1] = AAPL; fds[1] = AMZN_FEED;          // duplicate key
        vm.expectRevert(PartitioRouterV2.FeedMapBad.selector);
        new PartitioRouterV2(IPoolManager(PM), root, toks, fds);

        toks[1] = AMZN; fds[1] = address(0);          // zero feed
        vm.expectRevert(PartitioRouterV2.FeedMapBad.selector);
        new PartitioRouterV2(IPoolManager(PM), root, toks, fds);

        address[] memory shortFds = new address[](1);
        shortFds[0] = AAPL_FEED;                      // length mismatch
        vm.expectRevert(PartitioRouterV2.FeedMapBad.selector);
        new PartitioRouterV2(IPoolManager(PM), root, toks, shortFds);
    }

    /// Still no owner, so the binding cannot be changed after deployment.
    function test_R09_bindingIsImmutable() public view {
        bytes memory code = address(router).code;
        bytes4[3] memory forbidden = [
            bytes4(keccak256("setFeed(address,address)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 f = 0; f < forbidden.length; f++) {
            for (uint256 i = 0; i + 4 <= code.length; i++) {
                if (
                    code[i] == forbidden[f][0] && code[i + 1] == forbidden[f][1]
                        && code[i + 2] == forbidden[f][2] && code[i + 3] == forbidden[f][3]
                ) {
                    revert("router exposes a feed-mutating selector");
                }
            }
        }
    }
}
