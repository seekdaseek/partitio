# SECURITY

Tooling that actually ran: **Slither 0.11.x** (via `.venv-sec`, solc 0.8.26) over `src/v2/`.
Echidna/Medusa property fuzzing is **not yet run** and is not claimed anywhere.

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
