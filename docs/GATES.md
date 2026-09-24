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

**Funded and partly executed.** `cargo stylus check` passes against 4663: contract 6.0 KB (5 974
bytes), wasm data fee **0.000071 ETH** measured. The router and caller are deployed on mainnet and
three live swaps have settled — see `docs/DEPLOYMENTS.md`. The Stylus deploy itself is still
**UNTESTED**: `cargo stylus deploy --estimate-gas` returns 71,234,753,629,543 gas and a cost of
2955 ETH, which is a broken estimator rather than a price, so the deploy is attempted last with
0.000969 ETH remaining.

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

**Provenance note.** The brief listed no quoter address. `0x8dc178efb8111bb0973dd9d722ebeff267c98f94`
came from the `quoter` field of `/opt/bid-sampler/bid-markets.json` (August pre-event research, read as
reference only). That address is the **V4Quoter**, not the v3 QuoterV2 — a field name worth not
trusting. The v3 QuoterV2 is `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7`, taken from the official
Uniswap deployments file and proven live here.

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

### Finding: propAMM settlement is not router-gated — PROVEN BY SETTLEMENT

**The earlier evidence for this was not proof and has been replaced.** Identical
`ERC20InsufficientAllowance` reverts from an EOA and from the RialtoRouter only show there is no gate
*before* the token pull; a check placed *after* the pull would look exactly the same. Inference from
matching reverts was the wrong standard.

`test/PropAmmDirect.t.sol` settles real swaps on a pinned fork (block 71350874), called from a test
contract with no RialtoRouter anywhere in the call stack:

| maker | pair | quoted | received |
|---|---|---|---|
| fermi-prop AAPL | `0x89E211D4…ecF1` | 336.893742 | **336.893742** |
| fermi-prop TSLA | `0x6AF2ceE7…304b` | 376.152349 | **376.152349** |
| fermi-prop NVDA | `0x5744E9C5…f16F` | 222.950106 | **222.950106** |
| fermi-prop SPY  | `0x894b9322…cC73` | 764.501318 | **764.501318** |

Every fill equals its quote to the wei, and the returned value equals the balance delta. Partitio can
settle maker legs directly.

**This does not make maker legs safe to depend on.** Rialto's published spec says router-only, so the
absence of a check is a property of the currently deployed code, not a guarantee. Every maker leg is
therefore **best-effort**: if a leg reverts or fills short of its quote, the router sends that amount
to the best AMM venue **within the same call**, and total `minOut` is still enforced across the whole
route. A maker can degrade a route's price; it can never brick it. This is stated in the README.

`metric-propamm` (`0x8570D319…9625`, 40 051 code chars) does **not** answer `token0()` — a different
interface. It is **UNTESTED** and stays out of the registry until it has its own settlement proof.

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

**Superseded — see G7.** This sweep's hookless derivation is *not* the discovery mechanism. The
canonical RPC does serve `eth_getLogs`, so every pool including hook pools is enumerable from
events. The derivation sweep is retained only as an independent cross-check of the event data.

---

## G5 — Fork execution

**Status: PASS.**

`anvil --fork-url https://rpc.mainnet.chain.robinhood.com` boots and serves chain id 4663 at the live
head. The suite runs through `forge test --fork-url` directly, so anvil is not a dependency.

`test/G5Fork.t.sol` executes real v3 swaps **from a contract**, which is the entire premise of partitio
— an EOA doing this would prove nothing.

| venue | 1 AAPL → USDG | gas |
|---|---|---|
| canonical Uniswap v3, fee 500 | **336.815749** | 428 874 |
| `up-v3` fork, fee 500 / ts 60 | **336.892866** | 536 484 |

`test_G5_twoVenuesQuoteDifferently` asserts the two differ at the same block. They do, by 7.7e-5 USDG
per AAPL (~2.3 bps) — small at 1 unit, and it is exactly this gap that widens with size. This is the
split premise reduced to a passing assertion rather than a claim.

---

## G6 — Yardsticks (Kyber, LI.FI)

**Status: PASS, with an operational caveat.**

Both reachable **from the VPS**, AAPL → USDG at ~$1k (2.968 AAPL):

| yardstick | amountOut | note |
|---|---|---|
| KyberSwap all-sources | 999.906468 USDG | routed via `up-v3` pool `0x19d55aba…` |
| LI.FI `advanced/routes` | 997.829503 USDG | quotes AAPL at $337.0846 |

**Caveat:** Kyber returns HTTP 503 from the Mac and `code 50301 service temporarily overloaded` under
even light sequential load from the VPS (4 of 6 probes failed in one burst). The evidence engine must
pace requests and back off, and must record a failed yardstick call as `unmeasured` — never as 0.

---

## G4 addendum — the venue map is materially incomplete

Discovered while running G6, not by looking for it: the Kyber route for a $374k TSLA sell touches
**nine** distinct exchange families on 4663. My G4 sweep covers three of them.

| Kyber `exchange` | identifier form | in G4 sweep? | reachable from a contract? |
|---|---|---|---|
| `uniswapv3` | pool address | yes | yes |
| `uniswap-v4` | poolId | yes (hookless only) | yes |
| `up-v3` | pool address | **no** | yes |
| `uniswap-v4-fables` | poolId | **no** (hook pool) | yes |
| `uniswap-v4-arrakis` | poolId | **no** (hook pool) | yes |
| `fermi-prop` | pair address | partly — 11 of ≥15 | yes |
| `metric-propamm` | pair address | **no** | yes |
| `pmm-19` | *synthetic* `pmm_19_<tokenA>_<tokenB>` | n/a | **no — off-chain RFQ** |
| `kipseli-prop` | *synthetic* `kipseli-prop_<tokenA>_<tokenB>` | n/a | **no — off-chain RFQ** |

### The brief's "on-chain AMMs only" baseline is void

The brief's section 1 table has a column headed *"on-chain AMMs only (v3 + v4 + v4-fables +
kipseli-prop)"*, reading AAPL −0.95%, NVDA −0.75%, TSLA −2.12%, SPY −0.19%. **`kipseli-prop` is
addressed by a synthetic identifier, not a contract** — it is an off-chain RFQ source. Those four
numbers measure a source set no on-chain router can reach, and are discarded. They must not appear in
the README, the deck or the submission.

**Standing rule from here: no bytecode at the address, no venue.** A venue enters the registry only
after `eth_getCode` returns non-empty and its own accessors (`token0`/`token1`, plus `fee`/`tickSpacing`
or `getAmountOut`) answer. Synthetic identifiers are recorded as evidence of the off-chain gap, never
as routing targets.

**The two yardsticks are therefore:** (a) Kyber all-sources, and (b) Kyber restricted to venue families
proven to be contracts. (b) minus partitio is routing quality; (a) minus (b) is the off-chain maker
premium — a real limitation to state, not to hide.

Two consequences, both important:

1. **The product boundary is now measurable, not asserted.** `pmm-19` and `kipseli-prop` are addressed
   by synthetic identifiers, not contracts. No on-chain router can reach them — only an API can. Every
   other family is a contract partitio can call. The honest claim is therefore *"partitio routes the
   on-chain-reachable subset"*, and the gap to Kyber all-sources is the value of the off-chain makers.
   That gap is a number the evidence engine can measure, per ticker, per size.

2. **Kyber is a one-time discovery source for propAMM families only, never a runtime dependency.**
   I first recorded that hook poolIds needed Kyber because both RPCs refused `eth_getLogs`. That was
   wrong — see G7. Only `publicnode` refuses; the canonical RPC serves logs with no block-range limit.
   Uniswap v3 and v4 are therefore discovered from events, and Kyber is needed only for propAMM
   families (`fermi-prop`, `metric-propamm`) that expose no factory we can enumerate.

### `up-v3` is a standard v3 fork behind minimal proxies

Factory `0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3` — it does **not** expose `getPool` or
`feeAmountTickSpacing` (both revert), so its pools cannot be enumerated the canonical way.

Pool `0x19d55aba3e5d2c389b7011c634725136dfdcae33` is a 45-byte EIP-1167 clone of
`0x11725976bf1f38c4ab78d1f480bc5883d70d9dc3`, whose bytecode contains the full standard v3 pool
selector set: `swap`, `slot0`, `liquidity`, `fee`, `tickSpacing`, `ticks`, `tickBitmap`,
`uniswapV3SwapCallback`. Two deviations from canonical v3:

- `slot0()` returns **6** fields, not 7 (no `feeProtocol`). A shared 7-field signature fails to decode.
- fee 500 carries tickSpacing **60**, not 10. The canonical fee→tickSpacing mapping does not hold.

**Security consequence — this changes the design.** The brief specifies that the swap callback verify
`msg.sender` is the canonical pool computed from factory + tokens + fee. That CREATE2 derivation is
**invalid for clone-based forks**: an up-v3 pool's address is a function of the clone deployment, not
of the pool key. Callback authentication must therefore be **registry membership** — `msg.sender` must
be a venue the registry holds — rather than address derivation. Invariant I4 is restated accordingly:
*a callback from any address not in the venue registry reverts.*


---

# PIVOT GATES — gasless USDG-only stock trading (2026-09-24)

## G1 — Gasless sources

**Status: PASS. Both sides are gasless with signatures alone — no gas drip and no EIP-7702 needed.**

### USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`

USDG is a **proxy over an EIP-2535-style diamond**: 343 bytes at the token address, EIP-1967 impl
slot pointing at `0x68184c449e1a8f34fa18d289737129fd27b66f8f`, and unknown selectors revert with
`FacetNotFound`.

**A bytecode grep of that implementation is a false negative and was discarded.** Grepping the impl
for `receiveWithAuthorization`/`permit` selectors reported *absent* for every one of them — the
grep method itself was sound (control: `balanceOf` 0x70a08231 found, `0xdeadbeef` not found), but a
diamond dispatches through a selector→facet mapping in storage, so the selectors need not appear as
PUSH4 in the base implementation. The loupe (`facetAddress`, `facetAddresses`) is not exposed
either. **Live calls are the only authoritative test here.**

Revert-reason discriminator — `FacetNotFound` means the selector is absent, any other revert means
it exists and the input was bad:

| call | result | verdict |
|---|---|---|
| `permit(...)` dummy sig | `InvalidSignature` | **EIP-2612 present** |
| `receiveWithAuthorization(...)` dummy sig | `CallerMustBePayee` | **EIP-3009 present** |
| `transferWithAuthorization(...)` dummy sig | `InvalidSignature` | **EIP-3009 present** |
| `authorizationState(addr, nonce)` | `false` | present |
| `nonces(addr)` | `0` | present |
| `DOMAIN_SEPARATOR()` | `0x7a3d7400…b62036` | present |
| `version()` — absent control | `FacetNotFound` | correctly absent |
| `totalSupply()` — present control | 682,823,751 USDG | correctly present |

`CallerMustBePayee` is the useful detail: `receiveWithAuthorization` enforces `msg.sender == to`,
which binds an authorization to the contract that redeems it. That is exactly the front-running
protection GaslessEntry wants, and it means GaslessEntry must itself be the payee.

### Signed dry-run — the proof, not the inference

A real EIP-712 signature was built with a throwaway key and dry-run through `eth_call`:

```
domainSeparator 0x7a3d7400b27830f4f91c2c16a082486d67c1befecaec2f53b33f1f35d5b62036
typehash        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8
                keccak("ReceiveWithAuthorization(address from,address to,uint256 value,
                        uint256 validAfter,uint256 validBefore,bytes32 nonce)")
digest          0x1ef3a97ac764c379e1ac0b5242107967d4bc6befea73e27cd9fa1ae3e218ce4b
result          execution reverted: InsufficientFunds
```

`InsufficientFunds` is a **pass**: the call cleared the selector check, cleared `CallerMustBePayee`,
and cleared EIP-712 signature verification, failing only because the signer holds 0 USDG. The
domain separator, typehash, struct hash, digest and signature construction are all confirmed
correct against the live contract — which is the exact machinery B2 needs.

### Stock tokens

All five probed tokens are 569-byte proxies with an empty EIP-1967 slot (a different proxy
pattern), and all five answer identically:

| token | `permit` dummy | `nonces` | `DOMAIN_SEPARATOR` | `eip712Domain` | `uiMultiplier` | `paused()` |
|---|---|---|---|---|---|---|
| AAPL | `ECDSAInvalidSignature` | 0 | ✓ | ✓ | 1.000566080061092436 | false |
| TSLA | `ECDSAInvalidSignature` | 0 | ✓ | ✓ | 1.000000000000000000 | false |
| NVDA | `ECDSAInvalidSignature` | 0 | ✓ | ✓ | 1.000775159164630595 | false |
| SPY | `ECDSAInvalidSignature` | 0 | ✓ | ✓ | 1.001717991187472003 | false |
| QQQ | `ECDSAInvalidSignature` | 0 | ✓ | ✓ | 1.000700791241405425 | false |

`ECDSAInvalidSignature` is OpenZeppelin's error, so `permit` exists and reached signature recovery.
`uiMultiplier()` confirms ERC-8056. No pause is active and no transfer-restriction or allowlist
revert was observed on the read path — **UNTESTED** for an actual restricted transfer, which only a
live transfer between two non-allowlisted addresses would settle.

### Decision

**Neither fallback is needed.** Buys are gasless through USDG `receiveWithAuthorization` (EIP-3009,
payee-bound); sells are gasless through stock-token `permit` (EIP-2612). The sponsored gas drip and
the EIP-7702 smart-account path are both **dropped** — they were contingencies for a missing permit
that is not missing.

Gas context, at the live 0.0415 gwei: an approve costs 0.000002106 ETH and a measured partitio swap
0.000009265 ETH, so approve+swap is **0.000011370 ETH**. That is the bar a wallet must clear to
move its own position, and it is the threshold G2 measures against.

## G2 — The problem, measured

**Status: IN PROGRESS.** Scope constraint found and recorded: USDG exceeds the RPC's 10,000-result
log cap inside 10,000 blocks, and the chain is 71.4M blocks deep, so a full-history holder set is
not reachable through this RPC. The chain's Blockscout explorer
(`robinhoodchain.blockscout.com`) sits behind a Cloudflare challenge which was **not** circumvented.

The scan is therefore a bounded recent window, and the result is a **lower bound**. The bias is
conservative: wallets that transferred recently are more likely to hold ETH than dormant ones, so
the true zero-ETH population is at least as large as what this reports.

## G3 — Engine v2

**Status: NOT STARTED.**
