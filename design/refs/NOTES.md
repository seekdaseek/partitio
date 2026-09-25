# Reference screens — what each one actually does

Captured 2026-09-25 from live sites at 1280x900 (deviceScaleFactor 2), logged out, scratch browser
profile. Every claim below is read off the screenshot in this folder, not from memory.

| file | site | state captured |
|---|---|---|
| `01-robinhood.png` | robinhood.com/us/en/stocks/AAPL/ | full trade ticket, logged out |
| `02-matcha.png` | matcha.xyz — 1 ETH → USDC | full quote, no wallet |
| `03-cowswap-BLOCKED-cloudflare.png` | swap.cow.fi — 1 WETH → USDC | **quote blocked**, see below |
| `03b-kyberswap.png` | kyberswap.com — 1 ETH → USDC | full quote, no wallet (substitute for CoW) |
| `04-jupiter.png` | jup.ag — 10 SOL → USDC | full quote, no wallet |
| `05-uniswap.png` | app.uniswap.org — 1 ETH → USDC | quote only, details gated |

## CoW Swap could not be captured — and the substitute

`swap.cow.fi` loads, but the swap form sits behind a **Cloudflare Turnstile "Verify you are human"
checkbox** before it will return a quote. It appeared both in the headless capture browser *and* in
the desktop app's own built-in browser, so it is not a headless artefact. I do not complete CAPTCHAs,
so **CoW's quote card is unverified** — I never saw one. `03-cowswap-BLOCKED-cloudflare.png` is kept
as the honest record of where it stopped.

Substituted **KyberSwap** (`03b-kyberswap.png`), which is both a well-known swap UI and one of the two
aggregators partitio benchmarks against, so it is arguably a more useful reference than CoW anyway.

What I *could* see of CoW before the challenge: a Swap / Limit / TWAP tab row, a promo interstitial
("Cross-chain swaps are here") that occupies the entire card on first load and must be clicked past,
and an input-only card with the output field showing `0`. The CTA in the blocked state reads "Click
the checkbox" — the button text tracks the blocking condition rather than saying "Swap". That last
detail is worth keeping: **the CTA names the thing standing in the user's way.**

---

## 1. Robinhood — `01-robinhood.png`

**Quote card.** A persistent right-hand rail titled "Buy AAPL". Rows: `Invest In` (a Shares/Dollars
selector), `Shares` (input, `0`), then a cost ledger — `Market Price $336.00`, `Commissions $0.00`,
rule, `Estimated Cost $0.00` in bold. Below it a plain-language "How to buy Apple?" block, then a
green `Sign Up to Buy`, then a secondary `Trade AAPL Options` outline button.

**Price impact / slippage.** Neither exists. It is a broker, not an AMM — you get `Market Price` and
that is the whole story. No slippage control anywhere on the page.

**Before sign-in.** This is the important one. The ticket renders **completely** while logged out —
every row present, real market price, totals reading `$0.00` because quantity is `0`. Nothing is
hidden, greyed or replaced with a login wall. The only difference from a signed-in ticket is that
the CTA says `Sign Up to Buy` instead of `Buy`.

**Steal:** `Commissions $0.00` is a *line item in the cost ledger*, not a badge in the corner. The
zero is load-bearing — it sits in the same column, same type, same alignment as the numbers the user
is checking, so it reads as an audited fact rather than a marketing claim. partitio's "$0 gas"
belongs in the ledger next to the relayer fee, not in a pill.

## 2. Matcha — `02-matcha.png`

**Quote card.** From/To blocks each labelled with their chain. Sell side: token pill, `Clear / 50% /
Max` buttons, amount `1`, USD value `$2,691.70`. Buy side: `2,694.51` with `$2,694.33 (0.1%)` beside
it. Then two separate summary rows: **`You receive (incl. fee)  2,687.77 USDC`** with an info icon,
and **`Best route`** (with the winning venue's logo) alongside `⛽ Estimate · $0.272` and a chevron.

**Price impact / slippage.** Price impact is the bare `(0.1%)` appended to the buy-side USD value —
easy to miss. Slippage lives behind the gear icon, not on the face of the card.

**Before a wallet.** Full live quote, full fee breakdown, gas estimate in dollars. Only the CTA
changes: `Connect EVM wallet`.

**Steal:** the distinction between the headline output (`2,694.51`) and **`You receive (incl. fee)`
(`2,687.77`)** as two separate, both-visible numbers. That is exactly partitio's problem — the
relayer fee comes out of the order, so gross and net differ, and hiding the gap would be dishonest.
Also worth taking: **gas quoted in dollars, not gwei.**

## 3. KyberSwap — `03b-kyberswap.png` (substitute for CoW)

**Quote card.** Narrow ticket pinned to the **left rail**; the main area is a price chart. Ticket
rows: input `1 ETH ~$2,694`, `Est. Output 2693.5875… ~$2,694`, then `Max Slippage: 0.5%` as an
inline editable control, then a bordered details block — `Rate 1 ETH = 2,693.5876 USDC` with a
circular countdown timer, `Minimum Received 2,680.119658 USDC`, `Price Impact 0.02%`. Below the
whole page, a full-width **`Route: 1 ETH → 2693.5875 USDC`** strip with an expand chevron.

**Price impact / slippage.** Both are first-class named rows. Slippage is editable *on the card*, and
`Minimum Received` is shown as the consequence of that setting — the user sees the number the
slippage tolerance actually buys them.

**Before a wallet.** Full quote, full route, chart, everything. Only the CTA reads `Connect`.

**Steal:** two things. (a) **The route is a separate full-width strip**, not crammed into the ticket —
it gets its own horizontal band because it is its own kind of evidence. (b) the **countdown ring on
the rate row**, which says "this number has a shelf life" without any words.

## 4. Jupiter — `04-jupiter.png`

**Quote card.** Market / Limit / DCA tabs, an `Ultra` mode toggle. Sell `10 SOL ≈$1,175.29`, Buy
`1175.194255 USDC` with `≈$1,175.09 (-0.02%)`. One summary row: `Rate 1 SOL = 117.51 USDC ⇄` and, on
the right, **`ⓘ JIT (GoonFi V2 +3)`** — the entire multi-venue route compressed to "lead venue plus a
count". Below the card: `Show Chart` / `Show History` toggles and per-token cards with sparklines.

**Price impact / slippage.** Price impact is the `(-0.02%)` beside the USD value. Slippage is behind
the sliders icon.

**Before a wallet.** Full quote. CTA is `Connect`.

**Steal:** **`(GoonFi V2 +3)`** — naming the lead venue and counting the rest is the cheapest possible
summary of a split route, and it fits on one line at phone width. partitio can say
`Rialto MM-02 +3` in the collapsed state and expand to the per-leg table.

## 5. Uniswap — `05-uniswap.png`

**Quote card.** Sell / Buy blocks with USD values under each. One line under the button:
`1 USDC = 0.000371001 ETH ($1.00)` with a flip arrow.

**Price impact / slippage.** **Neither is shown.** I clicked the rate row to expand it and nothing
opened — with no wallet connected, the fee / network cost / price impact / order-routing detail panel
does not exist.

**Before a wallet.** Quote yes, evidence no. The CTA is `Get started`, and the entire justification
for the number is withheld until you connect.

**Steal:** nothing to copy — this is the **anti-pattern** partitio must avoid. It is the exact
failure mode the brief rules out: a believable number with no way to check it until you have skin in
the game. Worth keeping only as the negative control.

---

## What this means for partitio

1. **Robinhood proves the unconnected-but-complete ticket works** and is what a stock-trading
   audience already expects. Copy the structure, not the chrome.
2. **Nobody shows a comparison against rival venues.** Matcha says "Best route" and shows a logo;
   Kyber says "Route"; Jupiter says "+3". None of them says *how much better than the alternative*.
   partitio's per-venue and per-aggregator deltas are genuinely not present in any reference — that
   is the whole differentiator and it has no prior art to borrow from, so it has to be designed.
3. **Nobody shows an oracle check at all.** Same conclusion.
4. Gross vs net (Matcha) and Est. Output vs Minimum Received (Kyber) are the two places these UIs
   admit a number has caveats. partitio has three such gaps — relayer fee, slippage, oracle band —
   and needs a place to put each.
5. Gas is quoted in **dollars** everywhere it is quoted at all (Matcha `$0.272`, Robinhood
   `$0.00`). So partitio's is `$0.00`, not `0 ETH`.
