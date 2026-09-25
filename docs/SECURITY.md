# SECURITY

Tooling that actually ran: **Slither 0.11.x** (via `.venv-sec`, solc 0.8.26) over `src/v2/`, and
**Medusa 1.5.1** property fuzzing (7 properties, ~500k calls per campaign).

NOTE ON A PREVIOUS RUN: Medusa's config sets `slither.useSlither: true`, but slither lives in
`.venv-sec/bin` and was not on PATH for two campaigns, so the log carried
`Failed to run slither ... executable file not found` and the fuzzer ran without slither-derived
constant seeding. Fixed by putting `.venv-sec/bin` on PATH; recorded because a warning in a log
nobody reads is how a tool silently does not run.

Command:

```
slither src/v2/ --exclude-dependencies --exclude-informational --exclude-low
```

## Fixed

### unchecked-transfer — PartitioRouterV2 (6 sites) — FIXED

Raw `IERC20.transfer` / `transferFrom` / `approve` with the return value ignored. On this chain
that is not a theoretical concern: USDG is an EIP-2535 diamond and the stock tokens are beacon
proxies over a shared implementation, so "it will revert on failure" is an assumption about code
that can be upgraded underneath us.

Switched to OpenZeppelin `SafeERC20` (`safeTransfer`, `safeTransferFrom`, `forceApprove`)
throughout, including both callbacks. Slither results dropped 21 → 13 and the detector is gone.

## Justified, with a test that keeps them justified

### arbitrary-send-erc20-permit — GaslessEntry._pullIn — JUSTIFIED

> uses arbitrary `from` in `transferFrom` in combination with `permit`

`o.owner` is not arbitrary. `fill()` verifies `ECDSA.recover(orderHash, ...) == o.owner` at line
157, and `_pullIn` runs at line 163. The pull is authorised by the **order signature**, not by the
permit — the permit is only an optional convenience to create an allowance that may already exist.

The danger is a future edit that moves the signature check below the pull, which would make this
finding real and silent. So it is pinned by an adversarial test:
`test_cannotPullFromAVictimWithAStandingAllowance` gives a victim an unlimited standing allowance,
has an attacker sign an order draining them with the *wrong* key, and asserts `BadSignature` and an
unchanged victim balance.

### reentrancy-balance — PartitioRouterV2.swapExactIn — JUSTIFIED

Slither sees `before = balanceOf(this)` read across external calls and `amountOut` compared
afterwards. That is the intended balance-delta accounting, and `swapExactIn` is `nonReentrant`
(EIP-1153 transient guard, confirmed working on 4663). Venue callbacks are additionally pinned to
the in-flight callee in transient storage, so a registered-but-not-current pool cannot re-enter —
`test_I4_callbackFromRegisteredButNotInFlightPoolReverts` covers that.

Balance delta is deliberate rather than trusting a venue's return value: a hostile or buggy venue
that lies about its output cannot inflate the measured fill.

### uninitialized-local (5) — JUSTIFIED

`total`, `filled`, `unfilled`, `sum`, `usedAgg` are read after assignment in every path, and
Solidity zero-initialises. No behaviour change; left as-is rather than adding noise.

### unused-return (8) — JUSTIFIED

- `poolManager.unlock` and `poolManager.settle` return values are unused by design; the fill is
  measured by balance delta.
- `latestRoundData` is destructured for `answer` and `updatedAt` only. `roundId` and
  `answeredInRound` are deliberately not compared: Chainlink deprecated that staleness idiom, and
  the measured feed behaviour on this chain (0.5% deviation trigger, gaps to 87h) makes round-based
  freshness checks actively wrong here. See `docs/ORACLE-GUARD.md`.

## Design notes that are security properties

- **No owner anywhere in v2.** The venue set is an immutable Merkle root; the aggregator allowlist
  is four immutable addresses. Nothing can be added, paused or upgraded after deployment.
  `test_noOwnerNoSetter` scans the deployed runtime for admin selectors.
- **The aggregator leg cannot steal.** Exact approval, reset to zero immediately, balance-delta
  accounting, an allowlisted target only, and the user's `minOut` plus the oracle floor enforced on
  the final balance. A hostile route degrades price at worst; `test_failingAggregatorFallsBackInSameTx`
  proves a reverting route still fills through partitio in the same transaction.
- **Replay is locked twice.** The EIP-3009 authorization nonce *is* the order hash, so USDG's own
  `authorizationState` blocks a second use at the token level; an `executed` mapping covers the
  stock-selling path where `permit` carries no order binding.
- **Nothing at rest.** Every output transfer is followed by a zero-balance assertion that reverts
  on dust.

## Bugs found by the tests that were asked for, not by review

Three defects in GaslessEntry, each caught by a test written to the spec rather than to the code.

### 1. The fee was charged in the wrong asset on a sell

The fee was always taken from `tokenIn`, so selling AAPL would have paid the relayer **in AAPL**.
Now the fee is always USDG: deducted from the input on a buy, and from the USDG output on a sell.
`minOut` on a sell is checked against the **net** the user receives, so a fee can never push them
under the floor they signed for. A route with no USDG on either side reverts `FeeNotPayableInUSDG`
rather than silently charging in whatever asset was moving.

### 2. The aggregator path skipped the oracle guard entirely

The guard lives inside the router, so a route that went to an aggregator and never touched the
router was never guarded. Under a loose `minOut` that would have accepted an arbitrarily bad fill.
`OracleGuard.enforce` is now applied to the aggregator result too, on the measured `spent`/`got`.

Related: the acceptance bar for an aggregator leg was `out.minOut`, which is the *user's* floor and
usually loose enough for a poor fill to slip under. It is now `max(minOut, aggMinOut)` where
`aggMinOut` is what partitio itself would return — an aggregator route is only worth taking if it
beats our own.

### 3. Partial aggregator fills broke the fallback twice over

Found by `test_underDeliveringAggregatorFallsBackToPartitio`, which failed three times before the
code was right:

- **Legs were not rescaled.** They are quoted for the full input; after a partial fill only the
  remainder is available, so the router pulled more than the approval and reverted
  `InsufficientAllowance`. `_scaleLegs` now rescales proportionally, with rounding dust added to
  the last leg so the legs sum to the target exactly.
- **The fallback spent the reserved fee.** `remaining` read the whole balance including the fee
  earmarked for the relayer, so the payout at the end reverted `InsufficientFunds`. The reserve is
  now excluded.

## Not yet done

- Echidna or Medusa property fuzzing of GaslessEntry and the router invariants.
- Slither on the v1 contracts still deployed on mainnet (router/caller/Stylus). v1 remains live at
  the addresses in `docs/DEPLOYMENTS.md` and is superseded by v2, not upgraded.

### 4. The relayer's quote silently under-routed — found in the first smoke test

`POST /api/quote` for a 100 USDG AAPL buy returned **0.111 AAPL** where the best single venue gave
**0.296** — the split used one leg and 37.5% of the input.

Cause: the quote issues one JSON-RPC batch of up to 56 calls (venues × 8 ladder rungs). publicnode
accepts 30 and the canonical RPC tightens under load, so the upper rungs came back `null`, greedy
ran out of improving rungs and stopped early. A truncated batch looks exactly like a thin market.

Two fixes, because one would have hidden the other:

- **Batches are chunked at 25.** A partial result is now impossible rather than merely unlikely.
- **An invariant was added: partitio is never worse than the best single venue.** If the split
  total comes out below the best single venue's full-size quote, the whole order is routed to that
  venue instead. A partial split is a measurement failure, not a price — and this is the last line
  before a bad number reaches a user or a headline.

The response now also carries `unmeasuredRungs / totalRungs`, so thin coverage is visible in the
payload instead of quietly shrinking the split.

---

# Slither triage — final `src/`, 2026-09-25

Run against the frozen contracts, all impacts (the earlier run in this file excluded
informational and low). **108 detectors: 10 High, 27 Medium, 11 Low, 58 Informational,
2 Optimization.** Every High and Medium is dispositioned below. None is fixed by a code change,
and each says why rather than being waved away.

Raw output: `slither src/v2 --json` — re-runnable with `.venv-sec/bin` on PATH.

## High (10)

### `incorrect-exp` x1 — NOT OURS
`Math.mulDiv` in OpenZeppelin uses `(3 * denominator) ^ 2`. That `^` is a deliberate XOR in the
Newton–Raphson seed for a modular inverse, not a typo for `**`. Library code, known Slither false
positive, unchanged.

### `arbitrary-send-erc20-permit` x1 — FALSE POSITIVE, and already pinned by a test
`_pullIn` calls `safeTransferFrom(o.owner, address(this), o.amountIn)` after a `permit`. Slither's
concern is that `from` is attacker-controlled. It is not: `ECDSA.recover(oh, ...) != o.owner`
reverts at `GaslessEntry.sol:164`, **before** `_pullIn` at `:169`, so `o.owner` is by construction
the address that signed.

This is exactly the scenario `test_cannotPullFromAVictimWithAStandingAllowance` exists for — a
victim with a standing allowance and an order signed by somebody else, which must revert
`BadSignature`. **If anyone moves the ECDSA check below `_pullIn`, that test fails.** That is the
control, not this comment.

### `reentrancy-balance` x8 — THIS IS THE DESIGN, not a defect
All eight are the same shape: a balance read before an external call and used after it. That is
precisely the R-06 fix. `_execute` measures what a venue actually consumed as
`balBefore - balAfter` bracketed around the venue call, because trusting the call's return value
is what let short fills be booked as full fills and stranded the residue permanently.

Why the "stale balance" is not exploitable:
- `swapExactIn` is `nonReentrant` (EIP-1153 transient guard), so a venue cannot re-enter it.
- `_execute` is `internal`; the only re-entry surfaces are the two callbacks, and both authenticate
  against transient slots written immediately before the call (`T_EXPECTED`, `T_PAYTOKEN`,
  `T_BUDGET`, `T_UNLOCKED`) rather than against anything the caller supplies.
- Venues are Merkle-committed at deploy; an arbitrary contract cannot be a leg.
- A venue that *donates* tokenIn back mid-call can only make `used` smaller, never larger —
  `if (balAfter >= balBefore) return 0` and `if (used > amountIn) revert LegOverdraw`. The error is
  therefore conservative in the router's favour, and a donation ends up refunded to the payer.

Kept as-is deliberately: removing the pattern would mean going back to trusting return values,
which is the bug this code was written to fix.

## Medium (27)

### `divide-before-multiply` x10 — 9 in OpenZeppelin `Math.mulDiv`, 1 in `OracleGuard`
The OZ ones are library internals. The `OracleGuard` one is the decimal rescale, whose rounding
direction is deliberate and fuzzed: `testFuzz_decimalsRoundTripIsExactToOneWei` (256 runs) checks
it against an independently computed rational value, and `testFuzz_floorNeverRoundsAgainstTheFill`
(256 runs) checks the truncation can only ever favour the fill by at most one wei.

### `unused-return` x8 — deliberate on every site
Two shapes. `OracleGuard.enforce(...)`'s return values are discarded in `GaslessEntry.fill`,
because the *revert* is the product and `floorOut`/`updatedAt` are for callers that want to display
them. And `_viaRouter` discards `ROUTER.swapExactIn`'s return value on purpose — it measures the
result by bracketed balance delta instead, which is the R-01 fix. Using the return value there
would reintroduce exactly the accounting the review found broken.

### `uninitialized-local` x6 — accumulators
`legSum`, `orig`, `assigned`, `total`, `unfilled`, `filled`. Solidity zero-initialises; these are
sum accumulators whose first write is `+=`. No path reads them before the loop.

### `incorrect-equality` x3 — strict equality on a measured delta is the correct test
`used == 0`, `spent == 0`, `balAfter >= balBefore`. These compare quantities the contract itself
computed from two of its own balance reads, not an oracle or an external report, so `==` is exact
rather than approximate.

## Low (11) — noted, not actioned

`calls-loop` x6: external calls inside the leg loop **are** the router — a split across venues is
the product. A leg that reverts, declines or short-fills is handled (`try/catch`, measured
consumption, refund), which is what makes the loop safe rather than avoiding it.

`timestamp` x4: `block.timestamp` comparisons for the deadline, the feed-age ceiling, the signer's
`maxFeedAge` and the future-timestamp tolerance. All four are intended semantics; the tolerances
are measured rather than guessed (see `OracleGuard`'s own comments).

`reentrancy-events` x1: `AggregatorLegRejected` is emitted after the aggregator call in
`_fillSingle`. Event ordering only; no state is read after it.

## What Slither did NOT find

Worth stating, because a clean-ish Slither report is easy to over-read. It found none of the
twelve issues the independent review found, none of the twelve the follow-up audit found, and
neither of the two the adversarial hunters found — including the HIGH where an accepted aggregator
sliver ended the fill. Static analysis catches shapes; those were all semantics.
