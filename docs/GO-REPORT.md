# GO report — partitio v2 on Robinhood Chain 4663

Final verification closed 2026-09-27, deployed the same day. **Nothing HIGH or CRITICAL open.**

| gate | result | evidence |
|---|---|---|
| Independent review: 12 findings fixed | PASS | `3886648`, `docs/REVIEW-FIXES.md` §2; each PoC flipped, then rewritten positive |
| Follow-up audit: 12 findings in the fixes | PASS | judges: 12 CLOSED, 2 PARTIAL (both below) |
| Hunter HIGH (sliver fill burns order, full fee) | PASS | `d11ad43`; `test_H1_acceptedAggregatorSliverStillRoutesTheRemainder`, pro-rata `test_H2_aGenuinelyShortSpendEarnsAProportionalFee` |
| Dead store in the H-1 fix (`usedAggregator` always false) | PASS | `1571413`; `test_H1_theUsedAggregatorFlagReportsTheBranchThatActuallyRan`, negative-controlled |
| Final hunter on `b507c6c..HEAD -- src/` | PASS | `7f67ba6`: 0 HIGH, 0 MEDIUM, 4 LOW; 17 PoCs in `test/hunt/` reproduce |
| — LOW-1 transposed feed map | ACCEPTED | not catchable on-chain (expected hashes come from the same script); `predeploy-bindings.mjs` gates it: 35 bound, 35 distinct |
| — LOW-2 1–99 wei remainder bricks a fill | FIXED (relayer) | relayer writes the calldata and simulates first; refusal names it as a relayer bug |
| — LOW-3 `maxFeedAge` vs future feed | NOT A BUG | proposed fix applied, hunter's own 4 tests pass identically |
| — LOW-4 `maxFeedAge == 0` unguarded | ACCEPTED | dead order, no funds; relayer signs age-at-quote + deadline + headroom and refuses 0 |
| 2% default band, measured | PASS | `a8e6fa2`: $1k 0.8%, $10k 1.2% refused in open hours; no liquid ticker > 5% at retail size |
| Venue root: 161 venues verified on-chain | PASS | `2d622b3`; inverted pool + bad pool id are fatal (negative-controlled); all 161 prove via the router's own `_verify` |
| Feed map incl. 6 v4-only tickers | PASS | `2d622b3`; gaps IONQ −12.07%, RKLB −5.19% (ruled bound 09-25), CRCL +2.07% (weekend drift) |
| Relayer send path on a fork | PASS | `eff64d9`; `relayer/fork-e2e.mjs` 0 failures: buy 413,503 gas, sell 414,384, round trip 0.90% on $1 |
| Float burner 1: same order twice | PASS | one tx; duplicate refused by lock; resubmit refused as `AlreadyExecuted` |
| Float burner 2: two orders, one wallet | PASS | one tx; second refused by the wallet lock |
| Float burner 3: one key, stuck tx | PASS | sequential nonces; replaced at the same nonce; no earlier attempt mined |
| Every committed AAPL venue settles | PASS | `c1f33af`; `relayer/venue-probe.mjs`: 7/8 both ways incl. the maker; the 8th quotes zero, never selected |
| Fresh clone | PASS* | `ea6f70b`: 159/160; *the 1 is v1's I8 at $500k — v1 is not part of this deploy, v2 enforces never-worse-than-single off-chain |
| Deploy | PASS | router `0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA`, entry `0x9645388051ece3a437D5E224B17c156b16840AC7`; every immutable read back; gas equal to the fork to the unit |
| Source verification | PASS | Sourcify `exact_match` creation + runtime, both contracts |

## The 3 OPEN and 5 PARTIAL from the re-judge

| item | was | now | how |
|---|---|---|---|
| Sliver extraction (not in review or audit) | OPEN | CLOSED | accept branch falls through + pro-rata fee (`d11ad43`) |
| v4 `unlockCallback` path | OPEN | CLOSED | payload bound and consumed on entry; `test_H3_v4PoolDemandingMoreThanTheLegIsRefused` (inner bound = availability, outer = custody) |
| SGOV test discriminates the conventions? | OPEN | CLOSED | it did not — all 6 passed with the library flipped both ways; `test_theLibraryItselfUsesTheDecimalsOnlyConvention` fails the control |
| R-04 aggregator path unbounded | PARTIAL | CLOSED | same fix as the sliver |
| Gross vs net floor | PARTIAL | CLOSED | asserted at the guard: gross floor accepted, net-of-fee rejected (`84cbe18`) |
| R-08 budget vs fallback | PARTIAL | CLOSED | discriminating assertion: pool absorbed 520e6 vs its 200e6 leg (negative-controlled) |
| R-11 2% default | PARTIAL | CLOSED | measured (`a8e6fa2`) |
| R-12 permit nonces | PARTIAL | CLOSED | contract skips permit when allowance suffices; relayer's one-order-per-wallet lock serializes |
| `r01-spent-donation` (judges' last) | PARTIAL | CLOSED | Kyber CAN send anywhere; a mid-call donation is routed as the remainder, outflow = spent + fee exactly; a bad price cannot ride it past the floor (`0963b7f`) |
| Maker-leg grief | PARTIAL | KNOWN SHAPE | bounded by the signed `minOut` (`test_makerSliverGrief_isStoppedByARealisticMinOutNotByTheContract`) |

## Also found and fixed on the way

- 16 tests whose `vm.prank` was consumed by `_auth(o)`'s external call, so `fill` ran as the test contract (`0963b7f`).
- `rpc.mjs` dropped the node's revert data, so every refusal decoded as "unknown" (`eff64d9`).
- The revert decoder degraded silently without build artifacts; a fresh clone hit it (`ea6f70b`).
- The relayer's key file and RPC key were not gitignored (`039a577`).
