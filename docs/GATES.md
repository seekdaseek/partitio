# GATES — P0 verification log

Every row is either an observed result or marked **UNTESTED**. Nothing here is written from memory.
Chain reads are `eth_call` against `https://rpc.mainnet.chain.robinhood.com` unless stated.

Run date: 2026-09-24. Chain id **4663** (`eth_chainId`), block ~71.33M.

---

## G1 — Stylus on 4663

**Status: PARTIAL — precompile confirmed live, deploy+activate still UNTESTED.**

| probe | result |
|---|---|
| `eth_getCode(0x…0071)` | `0xfe` (precompile stub) |
| `ArbWasm.stylusVersion()` | **3** |
| `ArbWasm.inkPrice()` | 10000 |
| `ArbWasm.pageLimit()` | 128 |
| `ArbWasm.minInitGas()` | (8832, 352) |
| `ArbWasm.expiryDays()` | 365 |
| `ArbWasmCache (0x…0072)` code | `0xfe` |
| local `cargo-stylus` | **0.10.9** installed; `wasm32-unknown-unknown` target added |

A live `stylusVersion()` of 3 is far stronger evidence than the `0xfe` stub alone: the precompile is not
just present, it is configured. Note `version()` is **not** an ArbWasm method — it reverts; the correct
selector is `stylusVersion()`.

**Still required before G1 passes:** `cargo stylus check`, then deploy + activate on mainnet with the
throwaway key, and record the activation cost. Until that runs, the Stylus module stays a stretch goal.

---

## G2 — Uniswap and Morpho addresses

**Status: PASS.** Every address below was read from an official source, cross-checked against a second
source, and proven on-chain with `eth_getCode` plus one successful call.

Primary source: `github.com/Uniswap/contracts/blob/main/deployments/4663.md`.
Second source for the v4 set: the August bid-sampler config (pre-event research, read as reference only).

| contract | address | code | proving call | result |
|---|---|---|---|---|
| UniswapV3Factory | `0x1f7d7550b1b028f7571e69a784071f0205fd2efa` | yes | `getPool(AAPL,USDG,500)` | `0xAae0d815…B2d6D` |
| QuoterV2 (v3) | `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7` | 16 549 | `quoteExactInputSingle` 1 AAPL→USDG f500 | **336.869169 USDG**, gas 110 102 |
| PoolManager (v4) | `0x8366a39cc670b4001a1121b8f6a443a643e40951` | 48 021 | `owner()` | `0x2BAD8182…46CD` |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` | 7 065 | `getSlot0(TSLA poolId)` | tick −217017, lpFee 3000 |
| V4Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` | 12 239 | `quoteExactInputSingle` 1 TSLA→USDG | **374.980335 USDG**, gas 41 884 |
| Morpho Blue | `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` | 31 167 | `owner()` | `0x06059563…9728` |
| Permit2 | `0x000000000022d473030f116ddee9f6b43ac78ba3` | — | not yet used | UNTESTED |

Morpho Blue is independently confirmed for Robinhood Chain on `docs.morpho.org`, which also gives
AdaptiveCurveIRM `0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1` and ChainlinkOracleV2Factory
`0xB7c16F6F8cF531447Bf27Ca7220f981E79C9cdF2` (both **UNTESTED**).

**Correction to the brief's section 4:** the address listed there as the quoter,
`0x8dc178efb8111bb0973dd9d722ebeff267c98f94`, is the **V4Quoter**. The v3 QuoterV2 is a different
contract, `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7`.

---

## G3 — Rialto

**Status: PASS, with one finding that changes the architecture in our favour.**

Interface, from `docs.rialto.xyz/developers/standard-interface`:

```solidity
interface IPropPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getAmountOut(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);
    function swapExactIn(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline)
        external payable returns (uint256 amountOut);
}
```

Registry `0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E` (9 939 code chars),
Router `0xc94135b63772b91d79d0a2daab2a8801f32359bd` (48 467).
11 propAMM pairs located and probed — see `docs/VENUES.md`.

### Finding: propAMM settlement is NOT router-gated

The docs describe `swapExactIn` as "callable by RialtoRouter only". Measured on the AAPL pair
`0x89e211d43bbcf8ca5eaa9e5fbdef078cf520ecf1`, that is **not enforced on-chain**:

| caller (`eth_call --from`) | revert |
|---|---|
| random EOA `0x1111…1111` | `ERC20InsufficientAllowance(pair, 0, 1e18)` |
| RialtoRouter `0xc941…59bd` | `ERC20InsufficientAllowance(pair, 0, 1e18)` |

Both callers reach the token pull and fail there, identically. There is no `msg.sender`
discrimination. **Partitio can call propAMMs directly as a venue**, without routing through
RialtoRouter and without an off-chain quote.

Caveat: this is one pair at one block. It must be re-checked per pair before that pair is registered
as a venue, and it is a property of the current deployed code, not a guarantee. The venue adapter
must treat a revert as "maker declined" and continue, never as a router failure.

### Finding: refusal-by-zero confirmed empirically

`getAmountOut` on the AAPL pair, selling AAPL for USDG:

| AAPL in | USDG out | implied px |
|---|---|---|
| 1 | 337.091036 | 337.09 |
| 3 | 1 011.273108 | 337.09 |
| 30 | 10 102.490667 | 336.75 |
| 300 | 99 828.208332 | 332.76 |
| 1 500 | **0** | refused |
| 5 000 | **0** | refused |

The maker fills to somewhere between 300 and 1 500 AAPL (~$100k–$500k) and then declines. A `0` is a
refusal, not an error. Note the propAMM beats the v3 500-tier pool at 1 AAPL (337.09 vs 336.87) —
that spread is exactly what a split is for.

---

## G4 — Venue map

**Status: PASS.** Full results in `docs/VENUES.md`, raw data in `script/recon/venues.json`.

| | initialised | active liquidity |
|---|---|---|
| Uniswap v3 | 149 | 90 |
| Uniswap v4 (hookless) | 73 | 30 |
| Rialto propAMM | 11 | 11 pairs, caps vary |
| **total** | **233** | **120** + makers |

**28 of 37 tickers have ≥2 routable venues; 20 have ≥4.** AAPL has 7.

Two method notes, both the result of catching my own errors:

1. v4 poolId derivation was validated against two sampler-known poolIds (TSLA 3000/60 and SPY 500/10)
   **before** being used to discover anything. Both matched exactly.
2. The first sweep used `getLiquidity != 0` as the v4 existence test and silently dropped every
   initialised-but-idle pool. Re-run with `slot0.sqrtPriceX96 != 0`, the v4 count went from 30 to 73
   (e.g. META 1→4, NVDA 3→4). The `active` flag still records which have in-range liquidity now.

**Known gap:** hook pools are not enumerable — poolId needs the hook address as an input and both
public 4663 RPCs refuse `eth_getLogs`. They must be registered by address. Stated plainly rather than
claimed as zero.

---

## G5 — anvil fork

**Status: UNTESTED.**

## G6 — Yardsticks (Kyber, LI.FI)

**Status: UNTESTED.**
