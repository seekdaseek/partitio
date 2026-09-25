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

---

## 9. Final batch: maxFeedAge, minOut > 0, and the 4f answers

### Two new signed protections

**`minOut > 0` is now required.** A zero floor was the *root* of the sliver extraction both hunters
found: every defence the signer had left was the oracle band, and an honest price on a tiny amount
clears it. One wei satisfies the rule, so this is a stated-intent requirement rather than a size
rule — the contract will not guess a floor for you, but it will not accept an order that declines
to state one. `test_minOutZeroIsRefused`, `test_oneWeiMinOutIsAccepted`.

**`maxFeedAge` is signed in the order.** The floor is computed at FILL time, from a feed the signer
cannot see when they sign, at a block the relayer chooses. On a BUY the floor is `amountIn / price`,
so a stale-HIGH reference produces a LOWER floor: if the market gaps down and the feed has not
caught up, the relayer is handed more stock than the reference says and keeps the difference.
`enforce` returned `updatedAt` and its caller discarded it, so the signer had no way to bound it.

It is distinct from `MAX_AGE_SECONDS`: that is the library's absolute "is this feed alive at all"
ceiling and protects everybody; `maxFeedAge` is the signer's own bound and can only be tighter.
`test_maxFeedAgeStopsARelayerWaitingForTheFeedToGoStale` is the one that matters — same signature,
same route, only the clock moved, and the *deadline has not passed*, so it is demonstrably the
reference age that rejected it.

This is also what makes long-lived orders safe, and therefore what makes gasless limit buys
possible at all.

### Client defaults, in one place

`relayer/order.mjs` `marketOrderDefaults()`: deadline now + 120s, `maxFeedAge` = feed age at quote
+ deadline + 60s, `minOut` = quoted net x (1 − slippage) with slippage defaulting to 50 bps.
`rejectReasonForMarketOrder()` refuses a zero `minOut`, a zero `maxFeedAge`, or slippage above
300 bps before anything is signed.

### 4f, answered from source

| question | answer | where |
|---|---|---|
| Can a new contract call router v2 permissionlessly with its own legs? | **Yes.** `swapExactIn` is `external` with no caller restriction — zero `onlyOwner` or `require(msg.sender…)` in the file. | `PartitioRouterV2.sol:187` |
| Can GaslessEntry reach a new target without a redeploy? | **No.** `ROUTER` and `AGG0..AGG3` are all `immutable`. | `GaslessEntry.sol:74-78` |
| Max order deadline? | **None.** The only check is `block.timestamp > o.deadline`. | `GaslessEntry.sol:152` |
| Are order nonces unordered? | **Yes.** Replay protection is `mapping(bytes32 => bool) executed` keyed by the order hash, and the EIP-3009 nonce *is* that hash — random, not sequential. | `GaslessEntry.sol:80,161` |
| Can one user hold several open 3009-funded buy orders? | **Yes.** Distinct salts give distinct hashes give distinct 3009 nonces, and `receiveWithAuthorization` consumes no sequential counter. | — |

**So gasless limit buys are relayer + UI work only, and no contract change is needed.** The
one-line change that would have *blocked* them — a hard deadline cap — is deliberately NOT added:
`maxFeedAge` is the bound that makes a long-lived order safe, and it bounds the thing that actually
matters (the reference the fill is priced against) rather than the calendar.

Note the asymmetry this creates and accept it knowingly: the router is permissionlessly callable by
any future contract, so a Stylus `swapOnchain` could use it without a redeploy, but GaslessEntry
cannot reach a new target. Anything that wants to be inside the gasless path has to be there at
deploy time.

### Wallet prompts: the pitch says one signature, and that is not true

A buy takes **two**: the order signature (`ECDSA.recover` at `GaslessEntry.sol:164`) and the EIP-3009
authorization (`:254`). A sell takes **two**: the order signature and the EIP-2612 permit (`:263`).

A one-prompt buy is *possible* — the 3009 nonce already IS the order hash, so a user signing the
authorization is cryptographically committing to the order, and the separate order signature could
be dropped for the USDG path. It is not being done in this batch: it removes the `ECDSA.recover`
that `test_cannotPullFromAVictimWithAStandingAllowance` pins, it cannot work for sells (EIP-2612
has no field to carry an order hash), and it is not the kind of change to make in a freeze.

**The pitch gets reworded, not the contract**: "two signatures, zero gas, no ETH ever". The
honest claim is that the user never needs ETH and never sends a transaction, which is the part that
is actually unusual.

---

## 10. The single hunter on the unreviewed diff (2026-09-25)

One adversarial pass over `git diff b507c6c..HEAD -- src/` — the ~90 lines of money code that had
not been independently reviewed. **No HIGH, no MEDIUM.** Four LOWs, three corrections to my own
description of the diff, and one process finding. Seventeen PoCs live in `test/hunt/` and all
seventeen reproduce.

### Corrections to what I said the diff contained

I got two things wrong describing my own work, and the hunter caught both by reading
`git show b507c6c:` rather than taking the list at face value.

- **`feedOf`, the constructor map and `feedFor` already existed at `b507c6c`.** The only
  feed-binding change in this diff is the duplicate-FEED loop. I listed the whole binding as new.
- **The diff contains a router change I did not list:** `unlockCallback` now consumes its payload
  binding with `tstore(su, 0)` ON ENTRY (`PartitioRouterV2.sol:361`). An undocumented money-path
  change on an immutable contract is worse than a documented one; it is the fix behind
  `test_H3_secondUnlockCallbackInOneUnlockIsRefused` and it belongs in the list.
- **The buy-side fee CAP is algebraically unchanged by this diff.** With `S = amountIn − fee`,
  `feeDue/feeBasis = (fee·s/S) / (s + fee·s/S) = fee/(S + fee) = fee/amountIn` — `s` cancels
  exactly, so the new percentage check is identical to the old one, just evaluated after the swap.
  The fix is the pro-rata NUMERATOR, not the cap, and saying "the cap now binds against what really
  happened" overstated it. Relatedly, `if (feeDue > fee) feeDue = fee;` is unreachable: the two
  `forceApprove` bounds make `spent ≤ spendable` structural. It is dead defensive code.

### LOW-1 — the duplicate-feed check does not catch a TRANSPOSITION

`PartitioRouterV2.sol:135-137` compares each feed against every earlier one, so one feed on two
tokens is rejected. Two tokens whose feeds are SWAPPED are two distinct addresses and pass. That is
the same miswiring class the comment cites (CRWV pointed at CRCL's aggregator), and measured, AAPL
bound to AMZN's feed moves the reference 2,525 bps — outside `MAX_DEV_BPS`, so the band cannot
absorb it. Buys become permanently unfillable; sells let a relayer pay ~25% under fair value.

**Not fixed on-chain, deliberately.** The only constructor-level defence is a third array of
expected `description()` hashes — but those hashes would be produced by the same deploy script that
produces the feed list, so a transposition there yields matching wrong hashes and the check passes.
It buys nothing against the failure it is named for. The real net is off-chain and already exists:
`script/predeploy-bindings.mjs` builds the constructor args from a ticker-keyed join, asserts
`feed.description()` carries the ticker, and cross-checks the answer against the deepest v3 pool mid
at 2%. The comment in the constructor now claims only what it does.
PoC: `test_hunt3_constructorAcceptsAFullySwappedFeedMap`.

### LOW-2 — a 1-99 wei remainder bricks an otherwise honest fill

`GaslessEntry.sol:368-373`. The accepted-aggregator branch no longer returns, so the fall-through
runs unconditionally on `spendable - spent`. On a BUY (6dp in, 18dp out) a leftover of 1-99 wei of
USDG buys zero stock, and the router's own guard sees `spent > 0` with nothing delivered and reverts
the whole fill. Measured cliff: 0 wei settles, 1 and 10 wei revert, 100 wei and up settle. The sell
side is immune — an 18dp remainder rounds the 6dp floor to zero.

Nothing is lost: the revert rolls back `executed[orderHash]` and no funds move. **Fixed in the
relayer, not the contract.** The relayer writes the aggregator calldata, so it chooses the
remainder; and `submit.mjs` simulates before it broadcasts, so a bricking route is refused rather
than sent. Adding a dust constant to an immutable contract to paper over a relayer's own sizing bug
is the worse trade days before deployment. What WAS wrong was the sentence the trader saw: a
zero-output floor breach now says "the route left an unroutable remainder — this is a relayer bug,
not your order" instead of blaming the price.
PoCs: `test_hunt1_oneWeiRemainderBricksTheWholeFill`, `test_huntCliff_whichLeftoverSizesBrickTheFill`.

### LOW-3 — `maxFeedAge` and a future-dated feed: NOT ACTIONABLE, and I checked

Reported as "the bound fails open on a feed dated ahead of the chain clock", with a signed
comparison as the fix. I applied the proposed fix and re-ran the hunter's own four tests: **all four
pass identically.** With `age = -299` and `maxFeedAge = 0`, `-299 > 0` is false, so the signed form
permits exactly what the unsigned form permits. The fix is a no-op.

It is also the right semantics. A feed dated ahead is not "older than N" under any reading, the
window is bounded to 5 minutes by `MAX_AHEAD_SECONDS`, and a feed further ahead than that reverts
with `FeedFromTheFuture`. No change.

### LOW-4 — `maxFeedAge == 0` is not rejected on-chain, unlike `minOut == 0`

True, and the consequence is a dead order rather than lost funds — `executed[orderHash]` survives
the revert. The hunter's sharper observation is the useful one: measured live, AAPL's feed was
58,830 s (16.3 h) old, so ANY value tight enough to bound a market gap bricks the order, and any
value loose enough to fill is far wider than the gap.

That is the field's real job, and the relayer already implements it:
`marketOrderDefaults` signs `maxFeedAge = feedAgeAtQuote + deadline + headroom`, i.e. **relative to
the age actually observed at quote time**. It does not bound staleness in the abstract; it stops a
relayer sitting on a signed order waiting for the reference to go staler than it was when the user
agreed to the price. `rejectReasonForMarketOrder` refuses zero before any RPC call.

### The process finding, which is mine to own

The hunter watched `src/v2/OracleGuard.sol` change under it three times while it read — my own SGOV
negative controls, which shift every oracle floor by 51 bps. It handled that correctly: it worked
from a `git archive HEAD` copy and verified the md5 of all three sources before and after its final
run. It should not have had to. **A read-only agent reading the working tree and a negative control
mutating it cannot both run at once**; the controls belong in a worktree or the agent does.
