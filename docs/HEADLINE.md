# HEADLINE

Every bracket is a measurement. A bracket that has not been measured stays a bracket — it is never
filled with a plausible number, and this file is the only place the headline is allowed to live.

## Target line

> Morpho lenders on Robinhood Chain can't take stock collateral at size: a $500k AAPL liquidation
> through the best pool loses **[EXIT_SINGLE]%**, over [MULTIPLE] times its **[BREAKEVEN]%** margin.
> partitio clears it on-chain at **[EXIT_PARTITIO]%** in one call, split by a Stylus optimizer.
> **[N]** paired quotes over **[D]** days; **[$X]** of stock collateral made atomically liquidatable.

## Brackets and where each one comes from

| bracket | definition | source | status |
|---|---|---|---|
| `EXIT_SINGLE` | ≥24h median exit cost, $500k AAPL, best single venue, vs the market oracle's `price()` | engine v2 `agg` | **UNMEASURED** |
| `EXIT_PARTITIO` | same, partitio split | engine v2 `agg` | **UNMEASURED** |
| `BREAKEVEN` | `0.3 * (1 - LLTV)` uncapped, for the AAPL market's actual LLTV | Morpho Blue source + on-chain LLTV | **UNMEASURED** |
| `MULTIPLE` | `EXIT_SINGLE / BREAKEVEN` | derived | **UNMEASURED** |
| `N` | count of paired quotes, five digits required | engine v2 `quote` rows | **UNMEASURED** |
| `D` | days of continuous series, ≥5 required by Sep 30 | engine v2 `run` | clock starts tonight |
| `$X` | Σ atomic exit capacity across stock-collateral markets with supply > 0 | P3a capacity series | **UNMEASURED** |

## Rules this file enforces

1. **Medians over ≥24h, never a single sample.** The single-sample figures from run 4 (AAPL
   −14.6% → −1.7%, GOOGL −22.1% → −1.6%, TSLA −4.9% → −1.0%, COIN −25.9% → −5.3%, INTC −29.3% →
   −5.4%) are the reason to build the series. They are **not** quotable.
2. **Exit cost is measured against the market's own oracle `price()`**, not against a mid from the
   venue being measured. A pool quoted against itself cannot show its own slippage.
3. **Every uncertainty is biased against partitio.** Where the aggregator baseline is ambiguous,
   take its best observation, not its worst.
4. **If a number is not in the engine's database, it does not go in the line.**

## Kill criterion

If P0 shows there is no stock-collateral borrow to liquidate, or exit cost sits inside break-even
at every size, the thesis is wrong and the headline does not get written around it. Stop and report.
