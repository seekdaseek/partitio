# Mainnet deployments — Robinhood Chain (4663)

Deployer `0x7a7c915D8dA490c48915Fe735DDf41f8Dea83dC2` — a throwaway key generated for this build,
held 0600 outside the repo, never printed. Funded once with 0.001485471295631397 ETH; that is the
entire budget for the live proof.

## Contracts

| contract | address | tx |
|---|---|---|
| PartitioRouter | `0x732F703bAFB5B4375985cbfa9C37F3AEe3A03cbB` | `0x0db4c052a45d36b26602de9b87c54c826ff2442a0f708ca441b28d6a92a8b632` |
| PartitioCaller | `0x119aa61fC2c33F8e2c58370991Dc9fA5d6E3f399` | `0x5aa8d47b09487f6cf6327a8cc8ee693cf985409e5c8491fca845c5ebac36f9c0` |

Router constructor arg: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
Read back on-chain after deploy: `owner()` = the deployer, `poolManager()` = the address above.

## Budget, measured before the first transaction

Gas price 0.041448 gwei. **L1 component is 0** — confirmed with
`NodeInterface.gasEstimateComponents` (`0x…C8`), which returns `gasEstimateForL1 = 0` and
`l1BaseFeeEstimate = 0` on this chain, so there is no L1 data surcharge to budget for.

Required 0.000882737 ETH against a 0.001485471 ETH balance — 59.4% of budget, and it fit without
any of the stated cuts. Router deploy 1,877,027 gas and caller deploy 366,242 gas both came from
`eth_estimateGas` against mainnet; the swap figures were measured on a pinned fork.

**The Stylus line items are assumed, not measured.** `cargo stylus deploy --estimate-gas` returned
71,234,753,629,543 gas and a cost of 2955 ETH, which is a broken estimator rather than a price. The
wasm data fee of 0.000071 ETH is separately measured and is sound. Stylus is last in the order for
exactly this reason: the core system is live before that number meets reality.

## Live transactions

Every swap below was sent **by `PartitioCaller`, a contract** — not by an EOA. That is the whole
claim: a contract can route inside its own transaction. The deployer EOA only pays gas.

| step | tx | gas | in | out |
|---|---|---|---|---|
| register venues (2) | `0x9d976f846e094535cd013e8d1f78e86c7619827e1b158aefdd651fb3e4870d2d` | 195,083 | | |
| register venue 2 (corrected) | `0x9910198def49757ecc4878014c28b84bbbe9796d19768b6bfda4774a4415e926` | 102,384 | | |
| wrap 0.00038 ETH → WETH | `0xaeffe8e70830132f7a029afd26eaa355a92f8d4f4a691968e1e07d5ad413512c` | 57,647 | | |
| WETH → caller | `0x3ca48c58b373cf6ae86a492300dec95c9a664f768959bd83eafe7fdc6a360d4f` | 53,899 | | |
| **WETH → USDG** | `0xd8f02fc271fbf7104b7fc136c9fd0ceed90e389fd5b1a03cfb47141982133418` | 196,701 | 0.00038 WETH | **1.007445 USDG** |
| **USDG → AAPL** | `0x34b4c6bcf2bf379743ba66d38cda4a053ce09603c1917848cc5a501275637103` | 216,880 | 1.007445 USDG | **0.002987198956131552 AAPL** |
| **AAPL → USDG** | `0x7a04a17c2f6e6f901746a8718103b4b2241dfec371a2dcccea92e0a47b0c0024` | 219,326 | 0.002987198956131552 AAPL | **1.006437 USDG** |

**Stock-token round trip: 1.007445 → 1.006437 USDG, a 10.0 bps cost for two hops through real
AAPL liquidity.** The fork dry run predicted 10 bps, so the live result matched the measurement.

After all three swaps, read back on-chain: router AAPL balance 0, router USDG balance 0. **Invariant
I2 holds on mainnet**, not just on the fork.

## A mistake worth recording

The first WETH venue was registered with `token0`/`token1` inverted — I passed the pair in sorted
order by hand instead of reading it off the pool, and the pool has WETH as `token0`. The dry run
reverted, `cast send` refused to broadcast, and **no gas was burned** (nonce and balance unchanged).
Venue 2 was then registered with `token0`/`token1` read directly from `pool.token0()` /
`pool.token1()`, and every venue is now checked against its own pool before use.

Venue 0 is left in place and is simply unusable: a leg through it fails and, by the router's
best-effort design, falls back rather than bricking the route. It is a live demonstration that a bad
registry entry degrades a route instead of stealing from it.
