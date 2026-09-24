# Oracle guard — designed from measurement, not assumption

Inputs: 48,512 `feed_sample` rows collected since 2026-08-26, plus live reads of every Morpho
market oracle on 4663.

## 1. The feeds have a ~0.5% deviation threshold

|Δprice| between consecutive **distinct** feed updates, per feed:

| | median |Δ| | p25 | p95 |
|---|---|---|---|
| every one of 32 feeds | **0.448% – 0.558%** | ~0.51% | 0.58% – 2.10% |

The median sits at ~0.51% for **every single feed**, and p25 sits there too — the mass of updates
fires exactly at the trigger. The small tail (min, p05: 0.024%–0.142%) is heartbeat updates firing
on schedule regardless of movement.

**Conclusion: these feeds update on a ~0.5% deviation threshold.**

## 2. SPY's staleness is deviation mechanics, not market hours — confirmed

Age of `latestRoundData` split by US regular trading hours (13:30–20:00 UTC weekdays, EDT):

| ticker | RTH median | RTH p90 | off-hours median |
|---|---|---|---|
| SPY | **5.9h** | **19.8h** | 13.2h |
| QQQ | 3.3h | 12.6h | 11.1h |
| AAPL | 1.2h | 4.4h | 10.3h |
| MSTR | 12m | 57m | 1.2h |
| CLSK | 7m | 44m | 1.7h |
| all feeds | 30m | 3.6h | 4.4h |

**SPY is stale for hours *during* US market hours.** That is not the market being closed — it is a
broad index ETF that rarely moves 0.5% in a session, so a deviation-triggered feed simply does not
fire. The single names with high volatility (MSTR, CLSK, CRCL) update every few minutes.

**p99 and max across every ticker are 68–87 hours.** A weekend is only 65.5h, so those gaps exceed
market closure and represent holidays or feed outages. Staleness cannot be treated as a proxy for
"the market is shut".

## 3. What this forces on the guard

**A fixed staleness window is not viable.** A 1h limit would reject SPY more than half the time
during market hours. A 24h limit would still reject SPY around 10% of the time. A limit set to the
observed p99 (~70h) is no limit at all.

So the guard **never rejects on age**. It does three things instead:

1. **Band floor = deviation threshold + fee + slippage allowance.**
   The true price can sit up to **0.5%** away from the last answer without the feed updating, so
   any band tighter than 0.5% rejects honest fills. Floor:
   `0.5% (deviation) + pool fee (0.01%–1%) + slippage allowance`.
2. **Widen the band with age**, since age does not bound deviation — a stale feed means either "it
   has not moved 0.5%" or "the feed is down", and those are indistinguishable from outside.
3. **Label the reference**: show "last update HH:MM" next to the guarded price. Never silently
   block trading on a 24/7 chain because a stock feed has not ticked.

Checks that *do* hard-block: `answer > 0`, `updatedAt > 0`, `paused()` on the token, and one
**dead-feed ceiling**.

**Dead-feed ceiling = 120 hours.** The measured maximum age across all 48,512 samples and 32 feeds
is **87.4h**, which already spans holiday weekends. A ceiling above that catches a feed that has
genuinely stopped without ever rejecting a normal quiet period. It is not a staleness policy — it
is an upper bound on "is this feed alive at all". Tested with a mocked feed: 87.4h accepted, 119h
accepted, **121h rejected** as `FeedDead`.

No sequencer-uptime feed was found on 4663; if one appears it is added here.

## 4. Assets hidden in v1

| asset | reason |
|---|---|
| GLD, RDDT | priced by a "Uniswap V3 Pool Price in USD" feed. Using a pool price to guard a trade that moves that same pool is circular. |

**CRWV is not hidden.** An earlier note claimed it shared CRCL's feed; that was wrong. The live
CRWV market uses `0xe1b3aabc…` "Robinhood CRWV / USD" and agrees with it to 0.002%. See
`docs/FINDINGS.md`.

## 5. Never apply `uiMultiplier`

Robinhood's docs state the Chainlink feeds already incorporate the ERC-8056 `uiMultiplier`.
Verified: the AAPL feed reads 336.4003 against a 336.49 pool quote, while `uiMultiplier()` is
1.000566. Applying it again would double-count.
