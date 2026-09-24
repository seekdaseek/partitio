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

## Not yet done

- Echidna or Medusa property fuzzing of GaslessEntry and the router invariants.
- Slither on the v1 contracts still deployed on mainnet (router/caller/Stylus). v1 remains live at
  the addresses in `docs/DEPLOYMENTS.md` and is superseded by v2, not upgraded.
