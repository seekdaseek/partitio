# partitio UI — directions v2

Successors to `direction-a.html` / `direction-b.html`. Same two bets, pushed until the choice
between them is a real choice. Static single files, inline everything, no build step, no network
call except Google Fonts (both degrade to system stacks offline).

```
design/
  direction-a-v2.html   "the desk"    — dark console, whole market, everything is a column
  direction-b-v2.html   "the number"  — one 480px column, one hero number, sentences not tables
  DIRECTIONS-V2.md      this file
  direction-a.html      v1 (kept)
  direction-b.html      v1 (kept)
  refs/ shots/          reference captures + v1 renders
```

Both carry the **same order and the same numbers**, so they can be read side by side:
10,000.00 USDG → **29.7672 AAPL**, four venues, $0.00 gas, 1.83 USDG relayer fee, fill **−4.8 bps**
against a 336.04 Chainlink mark.

---

## The spine both directions share

Three things changed underneath the visuals, and they are what make the constraints carry.

**1. The refusal is computed, not staged.** Each ticker carries one number — where the on-chain mid
sits against the Chainlink mark, in bps — and every ticket is derived from it. A sell is refused
because `gross < refOut × (1 − band)` evaluates false, not because a state flag was set. Widen the
band and the same arithmetic lets it through, with the loss priced. Select a different ticker and
the refusal appears or disappears on its own. Neither page can show a refusal it cannot justify.

**2. The deviation is derived from the fills, never asserted beside them.** The headline bps is the
size-weighted average of the leg prices. A reader who multiplies 42% × 335.71 + 31% × 335.88 +
18% × 336.09 + 9% × 336.24 gets 335.8788, and 335.8788 against 336.04 is −4.8 bps, which is the
number on the page. v1 printed a headline that was 1 in the fourth decimal away from the sum of its
own legs; that class of error is now impossible.

**3. One sentence unifies constraints 1 and 5.** *The pools on 4663 sit under the Chainlink mark.*
That is why a buyer gets 29.7672 AAPL for what the mark says is 29.7529 — and it is the same fact
that floors a seller on a dislocated name. The split and the refusal stop being two unrelated
features and become two faces of one market condition. Both pages say it out loud; B makes it the
primary action on a refused sell ("buy it instead — the same dislocation, the other way round").

**Market hours run off the real clock.** Open the file at 14:00 UTC on a Tuesday and it says open,
with a live countdown to the close; open it on Saturday and it counts down to Monday. Nothing is
hardcoded, so the after-hours copy cannot be stale. RTH is 13:30–20:00 UTC, Mon–Fri.

---

## Direction A — "the desk"

### What it commits to

**The unit of the page is the market, not the order.** A is a console: a 12-row board on the left
with a sticky rail, a ticket in the middle, and an evidence column on the right that scrolls past
them. Every constraint is a **column or a row** — nothing is behind a disclosure triangle, nothing
is explained in prose, and nothing is softened. The refusal lives inside the ticket with its
arithmetic laid out line by line, and the blotter prints the literal
`BelowOracleFloor(got=8752400000, floorOut=9822790000, updatedAt=…)`.

It commits harder than v1 in three ways v1 could not: the board (v1 had no market view at all, only
one order), the sticky rails (the evidence now scrolls against a fixed ticket, which is what a desk
actually does), and the working-orders blotter, which is where the signed-but-unfilled state lives.
Palette and type are pushed further into terminal — IBM Plex Mono throughout, 10–12px, hairline
grid, amber reserved for "partitio wins" and nothing else.

### What it gives up

- **Comprehension by a newcomer.** Nothing on the page explains itself. You need to already own
  the words *band*, *bps*, *propAMM*, *minOut*, *maxFeedAge*.
- **Any emotional register.** The filled receipt is a six-column table. There is no moment.
- **The phone as a primary surface.** It reflows correctly at 375px — every table becomes
  label/value rows, no horizontal scroll anywhere — but it is a linearised desk, not a phone app.
  You scroll past twelve board rows and a constants panel to reach the ticket.
- **Shareability.** You cannot screenshot A into a tweet and have anyone care.

### Best: constraint 1, sells can be refused

A is the only direction that handles refusal at the **market** level rather than the order level.
The board carries a `sells floored — book 11.70% under mark` line under GOOGL and `2.62%` under
COIN, and the panel header reads `10 tradable · 2 sell-floored · 2 withheld`. You see which names
are refusing *before* you pick one, which turns "your sell was rejected" into "two of ten books are
dislocated today" — a market fact, not an error. Inside the ticket the arithmetic is fully shown
(oracle value → floor → best split → shortfall), the disabled CTA names the blocker rather than
saying "Swap", and the third option openly offers to widen the band to 1170 bps, states that the
on-chain ceiling is 2000 so it is legal, prices the loss at 1,159.70 USDG, and says partitio will
not preselect it. Take that option and the ticket fills — with a red block on top explaining what
you just agreed to and a one-click undo.

*Close second: constraint 5.* The six-column ledger prices every rival on the identical order in
three units at once, the leg table shows per-leg oracle deviation and the Rialto size cap, and a
row invites you to size-weight the four deltas and check the headline yourself. It is the only
artefact on either page that survives an adversarial reader.

### Worst: constraint 4, the gap between signed and filled

A's blotter states the facts — HELD, two attempts, deadline counting down, the revert string,
"the relayer paid the gas for both attempts" — and states them well. But the thing that matters
about *signed now, filled by someone else in six seconds* is the waiting, and a table row that
says HELD does not make anyone feel it. A shows you a log of other people's orders; it never shows
you your own order moving. B beats it decisively here and it is not close.

---

## Direction B — "the number"

### What it commits to

**One column at every width, one hero number, and sentences where A has tables.** 480px maximum on
a 27-inch monitor. There is not a single `<table>` in the file: the route is a ribbon plus four
lines of plain English, the comparison is four bars on a labelled zoomed axis, the oracle is a dial
and a paragraph. The explanatory voice is a serif (Newsreader) against Inter numerals, because the
commitment is that every constraint is delivered as something a person would actually say.

The big change from v1: **the card has states and you walk through them for real.** Sign an order
and it goes quote → signed → in flight → filled on a live clock. Sign a TSLA sell and it goes
quote → signed → *refused at block 71,341,208* → still live, retrying, countdown on your own
signature → filled on the retry. v1's "one number + three expanders" is still in there, but the
page is now a small application rather than a card. Light by default, real dark via
`prefers-color-scheme` plus a toggle.

### What it gives up

- **The market.** There is no board. You see one ticker at a time through a chip strip; running
  five names means five taps.
- **Auditability.** Nothing is scannable. You cannot compare two rows because there are no rows.
  The per-leg oracle deviation, the size cap, the "remaining venues not improving" note — all the
  detail a sceptic wants — simply is not there.
- **Density.** ~2,500px of page for one order. A fits an entire market above the fold.
- **Simultaneity.** The refusal *replaces* the quote. You cannot see the floored sell and the live
  buy at the same time, which is a real cost given that on a dislocated book those are the same
  screen's worth of information.

### Best: constraint 4, the gap between signed and filled

B is the only version that designs the gap instead of reporting it. Signed → relayer has it →
in flight → filled, each stage with its own elapsed time and its own sentence, and the honest line
underneath: *"There is a real gap here, usually a few seconds, and partitio would rather show it
than pretend it away. In that gap the price can move against you — which is exactly what the floor
is for."* When the fill is refused, the hero number becomes **the time left on your own signature**,
which is precisely the right number for that moment, and the page says the three things a worried
user needs in order: your order is still live, nothing was spent, the wasted gas was the relayer's.
No cancellation flow is offered because none is needed — the signature just dies at the deadline —
and B says so.

*Close second: constraint 2.* B's withheld-ticker state is the best writing on either page. The
hero becomes the bare symbol, then two calm paragraphs: the venues exist and the liquidity is real,
what is missing is an independent price, a floor taken from the pool it is guarding will agree with
any price you push it to, and GLD appears the day a Chainlink GLD/USD feed does. It explains an
absence without a hint of evasion and without blaming anyone.

### Worst: constraint 3, market hours

One sentence at the top and a `mark 41 min old` chip per ticker. It is correct, it is well written,
and a reader will skim straight past it. There is no way to learn that SPY's reference is six hours
old without selecting SPY. That matters more here than it looks: the measured finding in
`docs/ORACLE-GUARD.md` is that staleness is *deviation mechanics, not market hours* — SPY sits
stale for hours during the open while MSTR ticks every few minutes — so per-ticker reference age is
the real signal and the session banner is almost decorative beside it. A answers this with a REF
column that makes the whole market's staleness legible in one glance. B answers it one ticker at a
time.

---

## Which I would ship

**B — and I would graft two pieces of A into it before the first release.** The reasoning is that
this product's hard problem is not proving the split; it is surviving the refusals. A gasless
stock swapper on a chain whose thin books trade 11% under the oracle will refuse sells regularly,
and it will refuse some of them *after* the user has already signed. Both of those are language
problems before they are data problems, and B is decisively better at language: it tells a refused
seller that the book is 11.70% under the mark, that buying is the same dislocation the other way
round, and that signing and waiting costs nothing — where A tells them
`BelowOracleFloor(got=8752400000, …)`. The second answer is more truthful and the first one keeps
the user, and B manages to be both. B is also the only version that has designed the signed→filled
gap, which is the single most likely source of a support ticket in the whole product, and it is the
only one that works as a phone app, which is where someone buying tokenized AAPL with one signature
actually is. A's density is a genuine asset, but it is an asset for an audience — liquidators,
market makers, a judge with a calculator — that has not shown up yet and may never. The two grafts
that fix B's real weaknesses are cheap and neither one costs B its identity: put A's REF age on
every chip in the ticker strip (one field, repairs B's weakest constraint), and make
*"best of the four"* tappable through to A's six-column ledger (one screen, restores the proof B
throws away). If the first real users turn out to be liquidators rather than buyers, that reasoning
inverts cleanly and A is the right answer — so this is a bet on who arrives first, and I would bet
on the buyer.

---

## Grounded in the repo

| in both files | source |
|---|---|
| Band floor 50 bps, ceiling 2000 bps, dead-feed ceiling 120 h, feed-ahead tolerance 5 min | `src/v2/OracleGuard.sol` constants |
| `BelowOracleFloor(got, floorOut, updatedAt)` — the literal error A prints | `src/v2/OracleGuard.sol` |
| Max relayer fee 50 bps, fee comes off the **output** on a sell and the **input** on a buy | `src/v2/GaslessEntry.sol`, `MAX_FEE_BPS` |
| A refused order stays live: the signed order carries `deadline` + `salt`, and `executed[hash]` is only set on a fill | `GaslessEntry.Order`, `mapping executed` |
| Aggregator leg rejected mid-transaction, falls back to partitio in the same tx, no extra gas | `GaslessEntry`, `AggregatorLegRejected` |
| GLD and RDDT withheld — priced by a "Uniswap V3 Pool Price in USD" feed, circular | `docs/ORACLE-GUARD.md` §4, `docs/FINDINGS.md` |
| RTH 13:30–20:00 UTC; staleness is deviation mechanics, not market hours; 87.4 h observed max | `docs/ORACLE-GUARD.md` §2–3 |
| Per-ticker venue counts (AAPL 7, NVDA 10, GOOGL 7, COIN 3…) and Rialto caps (AAPL ≤300, NVDA ≤1000) | `docs/VENUES.md` |
| 233 venues mapped / 120 with active liquidity / 37 tickers / 28 splittable | `docs/VENUES.md` totals |
| AAPL mark 336.04 | within 0.02 of the measured oracle read 336.02 in `docs/PROBLEM.md` |
| Band composition `50 dev + 30 fee + 5 slip` | `docs/ORACLE-GUARD.md` §3.1 |
| Gas quoted in dollars as a **ledger line**, not a badge; complete ticket with no wallet | `refs/NOTES.md` — Robinhood, Matcha |
| The CTA names the blocker rather than saying "Swap" | `refs/NOTES.md` — CoW's blocked state |
| Route as its own band, separate from the ticket | `refs/NOTES.md` — KyberSwap |

## What I could not verify

1. **Every price is mock.** AAPL 336.04 is a hair off a real measured oracle read; the other eleven
   marks are invented. Nothing here is a quote.
2. **`Rialto MM-02`, `MM-03`, `MM-07` are invented maker labels.** `VENUES.md` records propAMM
   *caps*, not maker identifiers.
3. **KyberSwap and LI.FI are assumed to quote chain 4663 at all.** Not checked. If either does not,
   its row should read *no route* rather than a worse price — a better result for partitio and a
   different design.
4. **No block-explorer URL exists anywhere in the repo.** Every tx link in both files is an inert
   `#0x…` anchor. Supply a base URL and they become live.
5. **The 11.70% GOOGL dislocation is constructed to match the brief's example.** The repo's measured
   GOOGL figure (−18.51% best single venue, −1.31% split) is an *exit cost at $500k* — price impact
   at size, a different quantity from a dislocated mid. Both exist; only impact is measured.
6. **The 1.83 USDG relayer fee and the 5-minute order deadline are invented parameters.** Only the
   50 bps cap comes from the contract.
7. **Feed ages are invented**, though their shape follows the measured RTH medians (AAPL ~1.2 h,
   SPY ~5.9 h during the open).
8. **Neither file has been opened on a phone**, only at an emulated 375×812. Both were checked for
   horizontal overflow element by element at 375, 1024 and 1440 and report zero clipped nodes; that
   is not the same as having been held in a hand.

## Checked, not assumed

Both files were rendered and driven, not just written. At 375, 1024 and 1440 a DOM sweep for
`scrollWidth > clientWidth` returns **zero** clipped elements in each, across every ticker, both
sides, and every card state. Four real clips were found that way and fixed by resizing the layout
rather than by hiding the overflow: in A, a 306px board table inside a 268px rail and a 519px leg
table inside a 396px panel; in B, two route lines overflowing their 301px card by 6–8px on SPY and
GOOGL at 375, which now wrap. Every interactive path was exercised in
the browser: A's board selection, buy/sell toggle, the three refusal actions and the band-widening
undo; B's ticker strip, the full signed → in flight → filled sequence, the signed → refused →
still-live → filled sequence, the withheld-ticker state, and the dark-mode toggle. Both scripts
parse clean and neither logs a console error.
