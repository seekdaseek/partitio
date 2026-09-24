// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "./IAggregatorV3.sol";

/// @title OracleGuard
/// @notice Turns a Chainlink price into a floor on a swap's output.
///
/// DESIGNED FROM MEASUREMENT, NOT FROM HABIT — see docs/ORACLE-GUARD.md.
///
/// The usual pattern is "reject if the feed is older than N seconds". On Robinhood Chain that
/// breaks legitimate trading. Measured over 48,512 samples since 2026-08-26: these feeds fire on a
/// ~0.5% deviation threshold (median |change| between consecutive distinct updates is 0.448-0.558%
/// on every one of 32 feeds), so a slow-moving asset simply does not update. SPY's median feed age
/// *during US market hours* is 5.9h with a p90 of 19.8h, while volatile names update every few
/// minutes. A 1h staleness limit would reject SPY more than half the time; a 24h limit still
/// rejects it ~10% of the time; the observed p99 is ~70h, which is no limit at all.
///
/// So this guard NEVER rejects on ordinary age. It rejects on `answer <= 0`, on `updatedAt == 0`,
/// on a feed that has outlived every observed gap, and on a timestamp implausibly far in the
/// future. Otherwise it enforces an output floor whose width the caller chooses. Staleness is
/// surfaced to the caller as `updatedAt` so a UI can widen the band and label the reference time,
/// which is the honest response to a feed that cannot tell you whether it is quiet or dead.
///
/// WHAT THE CALLER MAY CHOOSE IS ONLY THE BAND. `feed` and the trade direction used to be fields of
/// `Params`, which meant the caller picked both the price source and which way to apply it —
/// pricing AAPL against the AMZN feed cut the floor by 27%, and inverting the direction collapsed
/// it by four orders of magnitude. Both are now supplied by `PartitioRouterV2` from an immutable
/// token->feed map and from the tokens actually being traded. See review findings R-09 and
/// `guard-direction-unbound`.
library OracleGuard {
    /// @param maxDevBps caller's maximum shortfall against the oracle, in basis points. This is the
    /// only thing left for a caller to choose, because it is the only thing that is genuinely a
    /// preference rather than a fact about the trade.
    struct Params {
        uint256 maxDevBps;
    }

    /// The true price can sit this far from the last answer without the feed updating at all,
    /// so any band tighter than this rejects honest fills. Measured, not guessed.
    uint256 internal constant DEVIATION_FLOOR_BPS = 50; // 0.50%
    uint256 internal constant MAX_DEV_BPS = 2000;       // 20% ceiling on what a caller may accept

    /// A dead feed still has to be caught. The measured MAXIMUM age across 48,512 samples and 32
    /// feeds is 87.4 hours, which already spans holiday weekends, so a ceiling above that catches
    /// a feed that has genuinely stopped without ever rejecting a normal quiet period. It is not a
    /// staleness policy — it is an upper bound on "this feed is alive at all".
    uint256 internal constant MAX_AGE_SECONDS = 120 hours;

    /// A feed reporting a timestamp in the future would otherwise skip the ceiling above entirely
    /// (review finding R-10): `block.timestamp - upd` is never evaluated when `upd` is ahead, so a
    /// feed stuck a year in the future reads as perfectly fresh forever.
    ///
    /// The tolerance is NOT zero, and that is a measurement rather than caution. Reading all 37
    /// feeds against one 4663 block on 2026-09-24 (block.timestamp 1790279182), TWO were already
    /// ahead of it: GLD by 11s and RDDT by 24s. A zero-tolerance revert would therefore have
    /// bricked those two tokens the moment it shipped. 5 minutes is ~12x the largest observed lead
    /// and still rejects anything that could hide a stopped feed.
    uint256 internal constant MAX_AHEAD_SECONDS = 5 minutes;

    error FeedBadAnswer(int256 answer);
    error FeedNeverUpdated();
    error FeedDead(uint256 updatedAt, uint256 age, uint256 maxAge);
    error FeedFromTheFuture(uint256 updatedAt, uint256 nowTs, uint256 tolerance);
    error BandTooTight(uint256 given, uint256 floorBps);
    error BandTooWide(uint256 given, uint256 maxBps);
    error BelowOracleFloor(uint256 got, uint256 floorOut, uint256 updatedAt);

    /// @notice The output the oracle says this input is worth, in tokenOut units.
    /// @param feed the aggregator pricing the STOCK side in USD. Supplied by the router from its
    /// immutable map, never by the caller.
    /// @param stockIsInput true when tokenIn is the stock and tokenOut is the USD stablecoin.
    /// Derived by the router from which side of the trade the mapped stock token is on.
    function oracleOut(address feed, bool stockIsInput, uint256 amountIn, uint8 decIn, uint8 decOut)
        internal
        view
        returns (uint256 out, uint256 updatedAt)
    {
        (, int256 answer,, uint256 upd,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert FeedBadAnswer(answer);
        if (upd == 0) revert FeedNeverUpdated();
        if (upd > block.timestamp + MAX_AHEAD_SECONDS) {
            revert FeedFromTheFuture(upd, block.timestamp, MAX_AHEAD_SECONDS);
        }
        // Only a feed that has outlived every observed gap is treated as dead.
        if (block.timestamp > upd && block.timestamp - upd > MAX_AGE_SECONDS) {
            revert FeedDead(upd, block.timestamp - upd, MAX_AGE_SECONDS);
        }
        updatedAt = upd;

        uint256 price = uint256(answer);
        uint8 feedDec = IAggregatorV3(feed).decimals();

        // NOTE ON ERC-8056 uiMultiplier. Stock tokens on 4663 carry a uiMultiplier(); 13 of 37 are
        // non-unit and SGOV is the largest at 51.02 bps, which EXCEEDS DEVIATION_FLOOR_BPS. It is
        // deliberately NOT applied here: the feed is priced per RAW token unit, which is what
        // balanceOf and every AMM move. Measured 2026-09-24 — real router fills on SGOV's 5 bps
        // pool agree with the reference below to 0 bps at 1k and 10k USDG. Applying the multiplier
        // would put that same honest fill 51 bps off, i.e. outside the tightest band this library
        // permits. test/review/SGOVMultiplier.t.sol pins this; do not "fix" it.
        if (stockIsInput) {
            // stock -> USD stable: out = amountIn * price, rescaled
            out = (amountIn * price * (10 ** decOut)) / ((10 ** decIn) * (10 ** feedDec));
        } else {
            // USD stable -> stock: out = amountIn / price, rescaled
            out = (amountIn * (10 ** decOut) * (10 ** feedDec)) / ((10 ** decIn) * price);
        }
    }

    /// @notice Enforce the floor. Reverts unless `got` is within `maxDevBps` of the oracle value.
    /// @dev The caller's band must clear DEVIATION_FLOOR_BPS. A caller trading size is expected to
    /// pass a band that also covers the expected price impact at that size — the quote returns the
    /// expected deviation so the UI can set it — because this guard exists to catch a broken or
    /// manipulated fill, never to block legitimate size impact.
    function enforce(
        Params memory p,
        address feed,
        bool stockIsInput,
        uint256 amountIn,
        uint256 got,
        uint8 decIn,
        uint8 decOut
    ) internal view returns (uint256 floorOut, uint256 updatedAt) {
        if (p.maxDevBps < DEVIATION_FLOOR_BPS) revert BandTooTight(p.maxDevBps, DEVIATION_FLOOR_BPS);
        if (p.maxDevBps > MAX_DEV_BPS) revert BandTooWide(p.maxDevBps, MAX_DEV_BPS);

        uint256 ref;
        (ref, updatedAt) = oracleOut(feed, stockIsInput, amountIn, decIn, decOut);
        floorOut = (ref * (10_000 - p.maxDevBps)) / 10_000;
        if (got < floorOut) revert BelowOracleFloor(got, floorOut, updatedAt);
    }
}
