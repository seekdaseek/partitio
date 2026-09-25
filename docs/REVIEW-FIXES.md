# Review fixes — what changed, and what each fix is pinned by

Companion to `docs/REVIEW-2026-09-25.md`. That file is the finding list as written; this one is the
disposition. Fix commit `3886648`.

**Read this first.** The review describes revision `ef15927`. `main` was two commits past it by the
time the fixes were written, and those commits had already closed some findings and introduced
others. Everything below was measured against `main`, not inherited from the report.

---

## 1. Already closed before any fix work

Measured by running the review's own PoCs against `main` at `fc51b58`:

| finding | closed by | evidence |
|---|---|---|
| R-02 (accept path only) | `0e4b72d` | the three aggregator PoCs began reverting `BelowOracleFloor` |
| R-04 | `0e4b72d` (`_scaleLegs`) | under-routing PoC delivered 2.944e18 instead of 2.94e16 |
| R-12 (on-chain half) | `0e4b72d` | permit is skipped when the allowance already suffices |

R-02 was only **half** closed, which is the subject of §3.

---

## 2. The twelve review findings

| # | status | fix | pinned by |
|---|---|---|---|
| R-01 | fixed | `DustLeftBehind` deleted; every amount is a bracketed delta; the input refund is a delta against a pre-`_pullIn` snapshot | `R01_DustDoS.t.sol` (4 tests) |
| R-02 | fixed | one aggregate `OracleGuard.enforce` in `fill`, over input measurably spent vs gross proceeds, after every branch | `R02_AggregatorGuardBypass.t.sol` (7 tests) |
| R-03 | fixed | every external call brackets its own before/after balance read | `test_R03_noopAggregatorFallsBackInsteadOfUnderflowing` |
| R-04 | fixed | raw `route.legs` must sum to exactly the spendable amount | `test_R04_slimLegsAreRejected`, `test_R04_fatLegsAreRejected` |
| R-05 | removed | `Order` carries one output; `Output`, `weightBps`, `MAX_OUTPUTS`, `BadWeights`, `TooManyOutputs` all gone | `test_R05_basketSurfaceIsGone` |
| R-06 | fixed | `_execute` returns measured consumption; both loops drive off it; residue re-routes then refunds | `R06_RouterStranding.t.sol` (3 tests) |
| R-07 | fixed | the callback settles in the leaf-committed token, read from transient storage | `test_R07_callbackSettlesInTheCommittedTokenNotThePoolsClaim` |
| R-08 | fixed | per-leg budget as a **decrementing** transient counter | `test_R08_singleOverdrawIsRefused`, `test_R08_repeatedCallbacksShareOneBudget` |
| R-09 | fixed | `Params` loses `feed` **and** `stockIsInput`; the router reads an immutable constructor map and derives direction from the pair | `R09_FeedBinding.t.sol` (7 tests) |
| R-10 | fixed | future `updatedAt` rejected, with a 5-minute tolerance | `test_R10_futureUpdatedAtIsRejected`, `test_R10_smallForwardSkewIsStillAccepted` |
| R-11 | no change | the 20% ceiling stays; the 2% default is app policy | `test_clean_bandFloorAndCeiling` |
| R-12 | partially fixed on-chain | permit is skipped when the allowance suffices; the ordering constraint is relayer/UI policy | `test_R12_secondPermitOrderIsBrickedByFillOrder` still documents the residual |

---

## 3. Findings the fixes themselves introduced or left open

An 8-way audit (27 agents) ran over `main` before the fixes were written. It found twelve confirmed
issues. These are the ones worth knowing about, because several are cases where implementing the
specification **literally** would have shipped a new bug.

### `agg-reject-path-unguarded` — critical, and not closed by the first R-02 fix

The guard added in `0e4b72d` sat inside the aggregator **accept** branch. A route *rejected* on
quality after consuming input was never guarded at all: the fallback only guarded the remainder.
Consume 500 of 999 USDG, deliver 10 wei of AAPL, be rejected, let the router honestly fill the rest
— the fill succeeds and half the order is gone. The review's own PoCs missed this because they all
made the aggregator eat 100% of the input, so the accept-path guard caught them.

### `aggminout-guard-offswitch` — the same hole, reachable deliberately

`route.aggMinOut` is relayer-supplied and not covered by the order signature. Setting it absurdly
high forced the rejection above, which is what removed the floor. It survives as a routing
preference only; the aggregate check covers both branches.

### `maxfee-denomination-sell` — the fee cap was loose by ~10¹²

`maxFee` was documented "in tokenIn units" while the fee has been paid in USDG since `0e4b72d`. On
an 18-decimal sell the signed cap therefore bounded nothing. Two test files in this repo already
disagreed about the field's units. Renamed `maxFeeUsdg` so the denomination is part of the signed
type, and bounded again by `MAX_FEE_BPS = 0.50%` of the USDG side.

### `router-tokenout-unchecked` — new, and the R-06 fix does not close it

`tokenOut` was never checked against the venue's committed pair, so a leg could point at a
correctly-committed pool for the **wrong** quote asset, spend real input and deposit a third token
that the output delta never counted. Measuring consumption does not help: such a leg consumes its
full amount. `_execute` now requires the committed pair to be exactly `{tokenIn, tokenOut}`.

### Three places the literal specification would have been wrong

- **`post-fee-guard-breaks-small-sells`.** "Delivered must be >= max(minOut, oracle floor)" taken on
  the *net* amount makes small sells fail arithmetically rather than on price: on a sell the fee
  comes out of the output, so a $5 sell with a $0.25 fee is 500 bps against a 200 bps band. The
  floor is taken on **gross** proceeds; the fee is bounded separately by `MAX_FEE_BPS` and the
  signed cap; `minOut` is checked on the **net**. This is a deliberate deviation.
- **`r07-r08-callback-data-forgeable`.** The review suggested encoding the committed token and
  budget into the callback's `data`. `data` is supplied by the **pool** — exactly the actor R-07 and
  R-08 defend against — so that fix would have been a no-op that still passed every mock. The values
  come from transient storage written by `_execute`.
- **`per-leg-budget-kills-fallback`.** A budget taken from the leg's *signed* amount would break the
  router's own cross-leg fallback, which deliberately hands one venue more than its own leg. The
  budget is the amount passed to that `_execute` invocation.

### R-10's tolerance is a measurement, not caution

Reading all 37 feeds against one 4663 block on 2026-09-24 (`block.timestamp` 1790279182), **two were
already ahead of it**: GLD by 11s and RDDT by 24s. A zero-tolerance "future = invalid" revert would
have bricked those two tokens on deploy. The tolerance is 5 minutes, ~12× the largest observed lead.

---

## 4. Why a constructor map rather than a second Merkle root (R-09)

The property needed is **one feed per token**. A mapping enforces that structurally — a duplicate
key is rejected at deploy. A Merkle multiset cannot: leaves `(AAPL, feedA)` and `(AAPL, feedB)` both
verify, and whoever supplies the proof picks.

That is not hypothetical here. Six tickers on 4663 — AAPL, GOOGL, NVDA, QQQ, SPY, TSLA — have a
second live aggregator, and the recon table that chose between them did so by "first Morpho market
per ticker wins", a rule that already miswired CRWV once (recorded in `chainlink-feeds.json`'s own
`note`). A root would have frozen an arbitrary choice behind an opaque 32-byte commitment.

`feedOf(AAPL)` is also one `eth_call` any reviewer can run against the deployed contract. A root is
only checkable by re-running the deployer's script, which is the trust an ownerless contract exists
to avoid.

Cost, measured: router deploy **2,995,196 gas** with all 37 bindings, entry **2,284,665**. At the
live price of 0.04472 gwei that is **0.000236 ETH** for both.

---

## 5. The SGOV convention lock

SGOV's ERC-8056 `uiMultiplier` is **51.02 bps** — larger than `OracleGuard.DEVIATION_FLOOR_BPS`
(50). So whether the guard applies it is not a rounding question: it decides whether the tightest
permitted band is usable on that token at all.

Measured 2026-09-24 against SGOV's 5 bps pool, real router fills agree with the **unmultiplied**
reference to **0 bps** at 1,000 and 10,000 USDG. Had the feed been quoted per UI share, that same
honest fill would sit 51 bps from the correct reference — outside a 50 bps band.

`test/review/SGOVMultiplier.t.sol` pins this both ways: it asserts the honest fill clears the
tightest band, and that applying the multiplier **would** reject it. It fails if anyone "corrects"
the guard, and it fails if Robinhood flips the convention.

---

## 6. A green suite that proves nothing

`test/fuzz/HarnessReachability.t.sol` exists because this already happened. After the fixes,
`property_aggregatorFillsClearTheOracleFloor` passed — **vacuously**. Every skimming route now
reverts on the floor, so no aggregator route ever completed a fill and the property was never
evaluated against anything. `aggFills` was 0.

The harness now carries an honest aggregator mode, and the reachability file asserts the counts:
buys 20, sells 20, honest aggregator route 20, and **40 skimming attempts complete 0 fills**.

### What the call count does and does not mean

**500,363 calls is not 500,363 calls of exploration.** The campaign reaches 2,249 branches within
about 21 seconds and ~25,000 calls, then finds nothing new for the remaining ~475,000 — the corpus
actually shrinks as it prunes. Read the headline as depth of repetition, not depth of search. Said
here because quoting the raw number as evidence of thoroughness would be the same kind of false
comfort as a vacuous property.

### Two coverage gaps found by reading lcov rather than trusting the passes

Both were found by the fresh-context re-verification, which passed everything and then went looking
for why.

| line | before | after | why |
|---|---|---|---|
| `FeedFromTheFuture` (R-10) | **0 hits** across 211,126 guard evaluations | 24,363 | `FuzzFeed.set()` always wrote `block.timestamp`, so the mock could never report a future timestamp and the branch was unreachable. R-10 rested entirely on unit tests. |
| `FeedDead` | 172,100 — **80% of all guard evaluations** | 8,496 | `blockTimestampDelayMax` was 604,800s against a 432,000s dead-feed ceiling, so a single block step could age the feed out. Pressure on the actual price floor was ~a fifth of nominal. |

`BelowOracleFloor` is now reached 156,138 times, against ~39,026 evaluations that previously
survived the age check at all.

### A note on `vm.expectRevert` that cost a cycle

In Foundry 1.8.1, `vm.expectRevert(bytes4)` means "the revert data is **exactly** these four bytes".
It therefore fails against any error carrying arguments, which is most of them here. Selector-only
matching is `vm.expectPartialRevert(bytes4)`. Ten assertions in the review tests were bare
`vm.expectRevert()` — passing on any revert at all, including one for an unrelated reason — and are
now typed. Two stay bare on purpose and say so: those reverts come from the USDG diamond, whose
error type is not ours to name.

The same class of blindness was in the original harness: it only ever built buys, which is exactly
where the fee-denomination bug is invisible, because on a buy the fee never touches the output.

---

## 7. Blocks the relayer, not the contracts

`relayer/quote.mjs` cannot submit orders against these contracts yet, and both reasons are verified:

1. `const chunk = amountIn / BigInt(K)` with `K = 8` is integer division, so the legs sum to
   `amountIn - (amountIn mod 8)` — up to 7 wei short. Verified: `amountIn = 12_345_678` produces
   legs summing to `12_345_672`.
2. The best-single-venue override at `quote.mjs:135-136` sets `legs[0].amountIn` to the **gross**
   `amountIn`, not `amountIn - fee`.

Both now revert with `LegsDoNotCoverOrder`. The quoter must quote on `amountIn - fee` and force the
last leg to absorb the division remainder.

Nothing is deployed and the relayer does not build orders yet, so the EIP-712 shape change costs
nothing downstream today. That window closes the moment the web app signs its first order.

---

## 8. Not covered

- The **v4 leg** remains the largest untested surface. `unlockCallback` now binds its payload hash
  and bounds the amount owed, but no test drives a real v4 pool through a short fill or a hostile
  hook.
- **Live Kyber and Rialto calldata**: the aggregator and maker paths are exercised with mocks that
  model the capability, not with a live route.
- **Token upgradeability**: USDG is a diamond and the stock tokens are beacon proxies. A facet or
  beacon upgrade can change semantics under both contracts.
- **No symbolic execution or formal verification.** Medusa only.
- R-12's ordering constraint is unfixed on-chain by design; it needs the relayer to process one
  order per owner at a time.
