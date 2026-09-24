# Stylus — PartitioMath

Deployed and activated on Robinhood Chain mainnet (4663).

> **Status: benchmarked, not in the production path.** Nothing in `src/` calls `PartitioMath`, and
> `PartitioRouterV2` does not compute a split at all — it executes the one handed to it in `legs`,
> which partitio's quoter computes off-chain. The numbers below are a real measurement of one
> algorithm against itself across two runtimes; they are not a claim about what a partitio swap
> currently executes. Do not let this table be read as "the split runs in Stylus in the same
> transaction". It does not.

| | |
|---|---|
| address | `0x2daccb7b03e8479ff52773682f3d1c9b295ceb41` |
| deploy tx | `0xdbf41db12c0a264a2e95528be428e1c01d2f493889813bc795318bba6cc9b97f` |
| activation tx | `0xf9dda825d79f69f4827e7d21924bd4f14b06991b5f0979a71c1e142d945c6599` |
| `ArbWasm.programVersion` | **3** (read back on-chain after activation) |
| wasm size | 7 569 bytes |
| wasm data fee | 0.000073 ETH (measured) |
| deploy + activate cost | 0.000271 ETH total |

Source: `stylus/partitio-math/src/lib.rs`. It is **not** a hello-world — it is the same greedy
allocator as `src/lib/GreedySplit.sol`, compiled to WASM, so the comparison below is of one
algorithm against itself rather than of two different programs.

## Gas table

Solidity figures are the library's own execution, measured with `gasleft()` in a Foundry test.
Stylus figures are `cast estimate` against the deployed contract on mainnet, so they **include the
21,000 transaction floor and the calldata cost** and the Solidity ones do not. The comparison is
therefore biased *against* Stylus, deliberately.

| workload | Solidity | Stylus | result | totals agree |
|---|---|---|---|---|
| 6 venues × K=8 | 40,470 | 61,797 | Solidity wins 1.53× | 9,140 ✓ |
| 12 venues × K=16 | 151,787 | 86,316 | **Stylus wins 1.76×** | 20,976 ✓ |
| 16 venues × K=32 | 400,396 | 140,752 | **Stylus wins 2.84×** | 44,544 ✓ |

Both implementations return byte-identical allocations and totals at every size, which is what
makes the gas numbers a fair comparison rather than a benchmark of two different behaviours.

## What the table actually says

**Stylus loses at small workloads and wins at large ones.** The crossover sits between 6×8 and
12×16. Stylus carries a fixed invocation overhead of roughly 45k gas — `ArbWasm.minInitGas` reads
(8832, 352) on this chain — which swamps a small allocation; past the crossover its far cheaper
arithmetic dominates and the gap widens with size.

That matters because K is the resolution of the split. K=8 is a coarse allocation; **K=32 across a
dozen venues is where a router actually wants to run, and that is precisely where Stylus turns a
400k-gas computation into a 141k-gas one.** The Stylus module does not make partitio faster
everywhere. It makes the *good* configuration affordable, and the honest claim is that one, not a
blanket speedup.

The 2×4 row is omitted because the Solidity and Stylus measurements used different input vectors
there and are not comparable. It is left out rather than quietly repaired.

## Not yet done

- The brief's original target for the Stylus module was `quoteV3` — simulating a v3 swap across
  initialised ticks, with a differential test against QuoterV2 to the wei. That is **UNTESTED and
  unbuilt**; the allocator was built instead because it is the hot loop that the router runs on
  every call, and because it could be cross-validated against an existing Solidity implementation.
- The router does **not yet call** this contract. Wiring it in is a router change plus a redeploy,
  and the current deployed router uses the Solidity library. Stated plainly: the gas table is real,
  the integration is not there yet.
- `cargo stylus cache bid` has not been run, so calls are not served from the ArbOS cache.
