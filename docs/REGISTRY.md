# REGISTRY — verified routable venues on Robinhood Chain (4663)

Discovered 2026-09-24T11:51:56.302Z · verified 2026-09-24T12:02:49.230Z

**Standing rule: no bytecode at the address, no venue.** Nothing enters this registry on the
strength of a log or a Kyber route. Every row answered for itself on-chain.

## How each family is discovered

| family | discovery | why |
|---|---|---|
| `uniswapv3` | `PoolCreated` logs, pair-filtered, full range | canonical factory emits it |
| `uniswap-v4` (incl. hook pools) | `Initialize` logs, pair-filtered, full range | poolId cannot be derived for hook pools |
| `fermi-prop` (Rialto propAMM) | Kyber routes, then proven by settlement | no enumerable factory |
| `up-v3` | **unsolved** — factory emits no `PoolCreated` | see Gaps |
| `metric-propamm` | **unsolved** — does not answer `token0()` | see Gaps |

The canonical RPC serves `eth_getLogs` with no block-range limit (10,000-result cap), so a
pair-filtered query covers all history in one call. `publicnode` refuses: archive token required.

## Funnel

| stage | v4 | v3 |
|---|---|---|
| discovered from logs | 3166 (1634 hooked) | 149 |
| rejected: no active liquidity | 2669 | 59 (idle or log/chain mismatch) |
| rejected: no bytecode | — | 0 |
| rejected: hook not a contract | 0 | — |
| **in registry** | **497** | **90** |

**587 verified venues**, plus 4 `fermi-prop` makers proven by settled swap.

Most discovered v4 pools are dead: 2,669 of 3,166 hold no liquidity. Discovery without
verification would have produced a registry that is 84% noise.

## Cross-check

v3 discovery was run twice by independent methods — `factory.getPool` across fee tiers, and
`PoolCreated` logs. Both produced **149 pools, 90 with active liquidity**. Agreement between two
methods is the reason to trust either.

## Venues per ticker

| ticker | v3 | v4 | of which hooked | total |
|---|---|---|---|---|
| NVDA | 6 | 48 | 24 | 54 |
| GME | 4 | 23 | 4 | 27 |
| AAPL | 4 | 22 | 4 | 26 |
| MSTR | 4 | 22 | 1 | 26 |
| SPCX | 5 | 20 | 6 | 25 |
| TSLA | 4 | 21 | 3 | 25 |
| GLD | 6 | 17 | 4 | 23 |
| GOOGL | 4 | 19 | 4 | 23 |
| META | 3 | 19 | 4 | 22 |
| SPY | 3 | 19 | 5 | 22 |
| RDDT | 4 | 16 | 0 | 20 |
| CRCL | 2 | 15 | 1 | 17 |
| DELL | 2 | 15 | 0 | 17 |
| TSM | 2 | 14 | 0 | 16 |
| COIN | 1 | 14 | 1 | 15 |
| INTC | 2 | 13 | 2 | 15 |
| QQQ | 3 | 12 | 1 | 15 |
| MSFT | 2 | 12 | 0 | 14 |
| SGOV | 3 | 11 | 1 | 14 |
| SNDK | 3 | 11 | 2 | 14 |
| AMZN | 1 | 12 | 1 | 13 |
| BABA | 3 | 9 | 0 | 12 |
| EWY | 0 | 12 | 0 | 12 |
| IONQ | 1 | 11 | 0 | 12 |
| PLTR | 2 | 10 | 0 | 12 |
| SLV | 4 | 8 | 0 | 12 |
| USO | 2 | 10 | 0 | 12 |
| ASML | 2 | 9 | 0 | 11 |
| MU | 3 | 7 | 3 | 10 |
| NBIS | 0 | 10 | 0 | 10 |
| AMD | 3 | 6 | 0 | 9 |
| CLSK | 0 | 6 | 0 | 6 |
| CRWV | 0 | 6 | 0 | 6 |
| ORCL | 0 | 6 | 0 | 6 |
| RKLB | 1 | 4 | 0 | 5 |
| USAR | 1 | 4 | 0 | 5 |
| RGTI | 0 | 4 | 0 | 4 |

## Hook contracts

40 distinct hook contracts, every one confirmed to have bytecode.

| hook | live pools |
|---|---|
| `0xc52fc52698479e42f0da9a8a75296ec3871454c0` | 15 |
| `0x64e9ae1066c47ac4a3cc0a5bd7b135908590e088` | 6 |
| `0x5eb87f69be00df39981622fd60a8de4b7837e080` | 5 |
| `0x11339fd1041614ea6e24d2b5d019fc5054256dec` | 3 |
| `0x05cbd7e5d0a3ba72d2be29c16ab3608db4634880` | 3 |
| `0x20f8b7ec9cc3bb5c739dedb15a8b4275f84b00c8` | 3 |
| `0x6d2ac09bf3e7be9e1898e8429b000bff6fb380c4` | 2 |
| `0xa4e6f5500e88691fdcb289aa0e99067481434880` | 2 |
| `0x70a9a88402989226847ec122043ce5e7ff462080` | 1 |
| `0x60d31599d69cd9aa6644e6402857c5cbf7d7e0c4` | 1 |
| `0xb608a78761f179f7c56f15e7d13921b92f00a080` | 1 |
| `0x92ff73eba2289c3b5c1b4a2fb50ea2012df53ec4` | 1 |
| `0x4bfe12797a92acdbd89bb6a119532163ba9a6080` | 1 |
| `0x08e52564bad99e05a694b4809f397edca417a080` | 1 |
| `0x1ba5d2f91352da1427b623e218555f4eed8ec5c7` | 1 |
| `0x73dfd2aec79c0e8990906628c1718f878f8ec0c8` | 1 |
| `0x8af95932ec4484fb10c641a4cbcf19a798cb2080` | 1 |
| `0xa824244844ef328745f2bf026353061263fa2880` | 1 |
| `0xa0ce1df0191a66434fb04391161776c7814f8a80` | 1 |
| `0x66622f77b797d506e5376f7798b67ab288966080` | 1 |
| `0x982cb9077d434d7d9625b2a5a41960601cff9080` | 1 |
| `0x535e42fd163ce2d612e46eb98f1ddbce9f5960c4` | 1 |
| `0xbd163d6f68c50a33ac8610cc8ae8e0134aa445c7` | 1 |
| `0xce2c659ce976fd937451ed24486b10f883a3aaa0` | 1 |
| `0x91d8f804112240af8fd900c9285de2eb1f9a6aa0` | 1 |
| `0xe348eec46639d60f5f9dfbedbcb494807bb56aa0` | 1 |
| `0x5f3a7401452504668a317cee424f2ee1071e40c4` | 1 |
| `0x40d251274e17d246c701f4ee2a21af79dc5b30c4` | 1 |
| `0xdf62b0884e37c77f35333bdc2f6eb13d77026800` | 1 |
| `0xab6304c60219850474c9658375ab6a5e72ff40c4` | 1 |
| `0x963cc847f470df5795ccf45cff39ceb69731bfff` | 1 |
| `0x3457d06efa90395a6b0696ad7522d1a416777fff` | 1 |
| `0x159bd01bc259de90b30360ad38ab3cbdcb67bfff` | 1 |
| `0x48b8f6ad3a1b4aa477314c9a23035b8f84dde8cc` | 1 |
| `0xf30f24b0a1885be51d6fa9b5b397f12b051e0088` | 1 |
| `0xf4f48bf7c0333ab56d418bdd5118d48674d6d040` | 1 |
| `0xa0e8fbff13e24af2b5e61a72800e08a161bde080` | 1 |
| `0xe35a363963dd10275fc2c6ae503ba65712830880` | 1 |
| `0xc60b5e5053136b54926b0faec8cad28c86c14880` | 1 |
| `0x67d86050d22d574df046f3d90f722045f714e080` | 1 |

## Gaps, stated plainly

- **`up-v3` — SOLVED.** Its factory `0x1ac9dB4a…B7F3` emits no `PoolCreated` and reverts on
  `getPool`, but it does emit its own event, topic0
  `0xab0d57f0df537bb25e80245ef7748fa62353808c54d6e528a9dd20887aed9ac2`, with `(token0, token1, fee)`
  indexed and the pool address in data. Found by reading every log the factory has ever emitted
  rather than guessing signatures; the signature name is still unidentified and does not matter.
  **1,877 pools exist; 61 are on our token universe; 28 hold liquidity**, at fee tiers
  1/10/50/60/100/200/2000 — nothing like Uniswap's. Nearly every ticker has one. Raw data in
  `script/recon/upv3.json`.

  **Not yet quotable.** Uniswap's QuoterV2 derives the pool address by CREATE2 from the canonical
  factory, so it cannot quote a fork's pools. up-v3 pools need either their own quoter, an
  `eth_call` state-override quoter (state overrides are confirmed working on this RPC), or the v3
  maths implemented directly — which is what the Stylus module is for. Until then they are in the
  registry but absent from the evidence engine.
- **`metric-propamm` does not answer `token0()`** and has different bytecode from the Rialto
  makers. Interface unknown. UNTESTED, excluded from the registry.
- **`pmm-19` and `kipseli-prop` are off-chain RFQ** addressed by synthetic identifiers. They are
  not reachable from any contract and are deliberately out of scope. The gap they represent is
  measured by the evidence engine rather than hidden.
- 4 discovery queries failed and are recorded as errors in discovered.json, not as zeros.


## The baseline is registry-scoped — read this before quoting any gain figure

`best single venue` in the evidence engine means **the best venue in this registry**, not the best
venue on the chain. Kyber routes on 4663 touch at least twelve families:

| family | in registry | reachable from a contract |
|---|---|---|
| `uniswapv3` | yes | yes |
| `uniswap-v4` (incl. the `fables` and `arrakis` hook pools) | yes | yes |
| `fermi-prop` | yes (11 pairs) | yes, settlement-proven |
| `up-v3` | discovered, **not quotable yet** | yes |
| `tessera` | **no** | unknown |
| `ramses-v3` | **no** | unknown |
| `manta-prop` | **no** | unknown |
| `metric-propamm` | **no** | unknown |
| `pancake-infinity-cl` | **no** | unknown |
| `alandale-v4` | **no** | likely (v4 hook family) |
| `pmm-19` | n/a | **no — synthetic id, off-chain RFQ** |
| `kipseli-prop` | n/a | **no — synthetic id, off-chain RFQ** |

**Consequence: every "gain versus best single venue" number is an UPPER BOUND.** If a deeper pool
exists in a family we have not indexed, the true best single venue is higher and the measured gain
shrinks. The error runs in the direction that flatters partitio, which is the direction that must
never be published unqualified.

Until the missing families are indexed, the defensible external comparison is **Kyber all-sources**,
which sees everything including the off-chain makers we cannot reach. On AAPL $500k that comparison
currently runs *against* us — Kyber 497,516.84 versus a 490,278.36 executed split, roughly 145 bps
behind — and that is the honest headline, not the registry-scoped figure.
