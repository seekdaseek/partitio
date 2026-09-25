# partitio web UI — two directions

Design exploration only. Nothing here touches `src/`, `test/` or `relayer/`. Static HTML, no JS,
no build step, no network calls.

```
design/
  refs/           5 reference screens + NOTES.md
  direction-a.html   "the ledger"
  direction-b.html   "the number"
  shots/          4 renders (desktop 1440 + phone 375, both directions)
```

Both directions carry the same order and the same numbers, so they can be compared directly:
**10,000.00 USDG → AAPL**, 4-venue split, net 29.5366 AAPL, $0.00 gas, +2.4 bps vs Chainlink.

---

## Direction A — "the ledger"

**The bet: the reader does not believe you, and the fastest way to win is to hand them the audit.**
The hero is not the amount — it is a six-column comparison table in which partitio is simply the top
row. Every rival route (best single venue, KyberSwap, LI.FI) is priced on the identical order and
shown with its shortfall in three units at once: tokens, bps and dollars. Nothing is collapsed,
nothing is behind a disclosure triangle. The ticket is demoted to a 330px left rail, and the route
split, the per-leg oracle deviations and the recent-fills log all sit on one screen beneath the
table. It is a desk layout: dark ink, tabular monospace figures, amber only where partitio wins.
It suits a judge scoring a submission, a trader comparing execution, or anyone whose first instinct
is to check the arithmetic — and the arithmetic does check out (the four per-leg deviations
size-weight to exactly the +2.4 bps headline).

**Prefer A if the first question your audience asks is "prove it"** — the comparison ledger *is* the
page, and the order ticket is a sidebar.

## Direction B — "the number"

**The bet: the reader already wants to trade, and every extra row is friction.**
One figure dominates: `29.5366 AAPL` at 62px, with the dollar value and per-share price beneath it
and four status pills — `$0.00 gas`, `+2.4 bps vs Chainlink · pass`, `4 venues`, `1 signature`. The
proof is still on the face of the card but it is graphic rather than tabular: the three rivals are
four horizontal bars on a zoomed axis (labelled "bars scaled from 29.4700", because at true scale a
15 bps gap is invisible), and the route split is a single stacked ribbon with venue chips. The
fine-grained evidence — per-leg fills, oracle band and staleness, the cost breakdown — lives in
three expandable strips, closed by default. Light, warm, centred, one column at every width. It
suits a retail buyer arriving from a link, and it is the version that survives being screenshotted
into a tweet.

**Prefer B if the first question is "how much do I get"** — one number answers it, and the proof
sits one glance below without being read.

They are not a repaint of one skeleton: A is a three-region desk grid whose hero is a table and
whose ticket is furniture; B is a single centred card whose hero is a typographic number and whose
evidence is progressive disclosure. The palettes differ (dark ink/amber vs warm light/green)
because the audiences differ, not for variety.

---

## What was taken from which reference

| Taken | From | Used in |
|---|---|---|
| `$0.00` as a **line item in the cost ledger**, not a badge — the zero is load-bearing because it sits in the same column and type as the numbers being checked | Robinhood, `Commissions $0.00` | A (ledger row "Network gas $0.00"), B (pill + Cost strip) |
| A **complete ticket with no wallet**, differing only in the CTA | Robinhood (`Sign Up to Buy`) | both — "No wallet connected · quote is live", CTA reads `Sign order — 1 signature` |
| **Gross and net as two visible numbers**, because the relayer fee comes out of the order and hiding the gap would be dishonest | Matcha, `You receive (incl. fee)` | A (Order size → Relayer fee → Routed to market → Net received) |
| **Gas quoted in dollars**, never gwei | Matcha `$0.272`, Robinhood `$0.00` | both |
| **Route as its own full-width band**, separate from the ticket — it is a different kind of evidence | KyberSwap's bottom `Route:` strip | A ("Route split" panel), B (ribbon section) |
| **Quote shelf-life made visible** | KyberSwap's countdown ring on the rate row | A (`Quote age 4s`), B (`quote refreshes every 4s`) |
| **"lead venue + count"** as a one-line route summary that fits at phone width | Jupiter, `JIT (GoonFi V2 +3)` | B's fills feed (`Rialto MM-02 +3`) |
| The **anti-pattern to avoid**: a believable number whose justification is withheld until you connect | Uniswap — price impact and routing simply do not render logged out | both — this is why the evidence is unconditional in A and only one click deep in B |

Two things had **no prior art in any reference** and had to be designed rather than borrowed: the
per-rival delta (none of the five tells you how much better it is than the alternative — they all
just assert "best route"), and the oracle check (nobody shows one at all).

## Grounded in the repo, not invented

- **Venue mix** — `docs/VENUES.md` records AAPL with 7 routable venues at block 71,335,790:
  `v3:USDG/500`, `v3:USDG/3000`, `v3:USDG/10000`, `v3:WETH/500`, `v4:USDG/3000`, `v4:USDG/10000`,
  `rialto≤300`. The 4-leg split in both mockups uses only venues from that list, and the block
  number in A's hero header is that recon block.
- **Oracle band** — `docs/ORACLE-GUARD.md` derives a band *floor* of
  `0.5% deviation + pool fee + slippage`. The mockups show `±85 bps` and spell out the composition
  as `50 dev + 30 fee + 5 slip`, and carry the measured **120h dead-feed ceiling**.
- **Feed staleness is labelled, not hidden** — the same doc requires showing "last update HH:MM"
  next to the guarded price, so both directions print `11:18 UTC · 1h 23m` rather than implying the
  reference is live.

## What I could not verify

1. **CoW Swap's quote card — never seen.** `swap.cow.fi` gates quoting behind a Cloudflare Turnstile
   checkbox, in the headless capture browser *and* in the desktop app's own browser. I do not solve
   CAPTCHAs. The blocked state is saved as `refs/03-cowswap-BLOCKED-cloudflare.png` and I substituted
   **KyberSwap** (`refs/03b-kyberswap.png`), which is also one of partitio's two benchmark
   aggregators. Any claim about how CoW presents a quote is therefore absent from NOTES.md.
2. **Block-explorer URL.** No explorer URL appears anywhere in `docs/`, `README.md` or
   `foundry.toml` — only the RPC `https://rpc.mainnet.chain.robinhood.com`. The tx links in both
   mockups are inert `#tx-…` placeholders. Supply the real explorer base and they become live.
3. **Every number is plausible mock data, not a live quote.** Grounded in shape (see above) but not
   measured. In particular I did not verify that KyberSwap or LI.FI quote chain 4663 at all — the
   comparison assumes they do. If either does not, that row should read "no route" rather than a
   worse price, which is a *better* result for partitio but a different design.
4. **`Rialto MM-02` is an invented maker label.** `VENUES.md` records propAMM *caps* (`≤300 units`
   for AAPL), not maker identifiers.
5. **AAPL price.** The brief said ~$338 and the mockups use a $338.42 Chainlink reference; the live
   Robinhood page captured the same day showed **$336.00**. Fine for a mockup, not a real mark.
6. The relayer fee (1.84 USDG) and the 4s quote refresh are invented parameters.

## Renders

Captured at deviceScaleFactor 2, full page, and each one inspected before being accepted.
Direction B's 375px render was additionally re-checked in the desktop app's built-in browser and
matches. Two layout bugs were found *by looking at the shots* and fixed rather than reported:
a CSS class-name collision in A that threw the "Network gas $0.00" row into the page header, and
three phone-width overflows in B (truncated amount fields, a bar label clipped to `4788`, and the
oracle summary running off the right edge).

| | desktop 1440 | phone 375 |
|---|---|---|
| A | `shots/direction-a-desktop-1440.png` | `shots/direction-a-phone-375.png` |
| B | `shots/direction-b-desktop-1440.png` | `shots/direction-b-phone-375.png` |
