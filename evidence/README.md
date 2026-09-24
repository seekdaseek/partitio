# partitio evidence engine

Live on the VPS as PM2 `partitio-evidence`, `/opt/partitio-evidence`, SQLite `partitio.db`,
read-only JSON on `:3030` (`/health`, `/latest`, `/summary`). Runs every 10 minutes.

Per run, for 18 tickers × {$1k, $10k, $100k, $500k} sold into USDG:

- **per-venue on-chain quotes** by `eth_call` — QuoterV2 (v3), V4Quoter (v4, including hook pools),
  `getAmountOut` (Rialto makers). Each venue is quoted at 8 cumulative ladder points so the
  marginal-output curve is measured, not assumed.
- **best single venue** and **best single protocol** (best v3 / best v4 / best maker).
- **the greedy split** over those same quotes, labelled `split_sim`. It becomes `split_router`,
  read by `eth_call` from the deployed contract, once `PARTITIO_ROUTER` is set. The label always
  names its source.
- **Kyber all-sources** and **Kyber restricted to proven-contract families**.

## Rules this engine enforces

**A failed call is `unmeasured` with `amount_out` NULL — never an imputed zero.** A maker that
returns 0 is `refused`, which is a different fact, and both are kept distinguishable in the data.

**The `includedSources` restriction is not trusted.** Every restricted response is checked against
the families that actually came back; if an off-chain source leaks in, the row is recorded
`unmeasured` naming the leak rather than used as an on-chain baseline. Trusting that parameter is
how the brief's void "on-chain AMMs only" column came to include `kipseli-prop`.

**Kyber returns degraded routes under load.** Measured 2026-09-24: the same AAPL $500k order
returned 497,516.842698 on one call and 426,385.109388 minutes later — a 15% spread, the low
reading collapsing onto a single venue. A degraded baseline flatters partitio, which is the most
dangerous direction for an error to run, so every response records its hop count and family list,
and headline comparisons take the **best** Kyber observation per cell across runs, never one
sample. Every uncertainty is biased against partitio.

**Kyber is sampled on rotation** — one third of the grid per run — because 144 Kyber calls cannot
fit in a 10-minute window under its rate limit. The on-chain grid still runs in full every 10
minutes.

## Known gaps

- v4 quotes revert at larger sizes when a pool cannot fill; these are `unmeasured` and correctly
  stop the greedy allocator from using that venue beyond that size. A handful revert even at the
  smallest size — those venues are candidates for removal from the registry. UNTRIAGED.
- LI.FI is wired but not yet called (`lifi_status = 'skipped'`); it is capped at hourly by design.
- `split_sim` is computed from quotes. **Quotes are not execution.** Until the fork execution test
  (invariant I8) confirms that a split's legs actually fill at their quoted amounts, every
  `split_sim` figure is UNVERIFIED and must not be published.
