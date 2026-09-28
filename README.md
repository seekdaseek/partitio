# partitio

> **A $100,000 stock-token order on Robinhood Chain sent to the best single pool left a median $199
> on the table in 6,329 of 7,493 executable quotes. partitio splits it and floors the fill against
> Chainlink.**
>
> Quoted, not executed · the beta caps trades at $50 · runs 1–245, Sep 24–27, 2026 · query:
> [`evidence/headline.mjs`](evidence/headline.mjs), recomputable offline with
> [`evidence/headline-offline.mjs`](evidence/headline-offline.mjs)

**Live:** https://partitio.ochinimus.app — quotes need no wallet. Try
[$100,000 of AAPL](https://partitio.ochinimus.app/?amt=100000) and watch the split against the best
single pool.

**Verify every claim in five minutes:** [JUDGE_GUIDE.md](JUDGE_GUIDE.md).

---

## What it does

Robinhood Chain lists tokenized stocks across dozens of Uniswap v3 pools, Uniswap v4 pools and
maker pairs. At retail size one pool is usually best. At size, no single pool is: the order walks
down one pool's curve while the others sit idle.

partitio quotes every committed venue for the stock, splits the order across them **only when the
split beats the best single pool**, and otherwise sends it to that pool alone — so it is never worse
than the best pool at quote time. Then three things are enforced on-chain, where a relayer cannot
argue with them:

1. **The venues.** The router commits to 161 venues by an immutable Merkle root. Every leg carries
   a proof; a venue outside the set cannot be used.
2. **The price.** Every fill is checked against the stock's Chainlink feed inside the contract. A
   fill outside the signed band (2% by default) reverts instead of filling.
3. **The floor.** The user signs a minimum output. Anything less reverts.

And the user needs **no ETH**. They sign two EIP-712 messages — the order, and an authorization for
exactly this order's funds (USDG's EIP-3009 `receiveWithAuthorization` on a buy, the stock's
EIP-2612 permit on a sell) — and a relayer submits the transaction and pays the gas.

## The fee

Not a percentage. The fee is **the network gas of the chosen route, paid in USDG**, plus **20% of
what the split saved over the best single pool**, which is zero unless the split beats it. Capped at
0.50% of the trade and at 5 USDG, and charged pro rata on what actually fills. At $50 of AAPL through
one pool that is about $0.007; the relayer's own ~280k gas of overhead is on us.

## Contracts — Robinhood Chain (4663)

Ownerless and immutable: no owner, no pause, no upgrade, no sweep.

| contract | address | source |
|---|---|---|
| GaslessEntry | [`0x9645388051ece3a437D5E224B17c156b16840AC7`](https://robinhoodchain.blockscout.com/address/0x9645388051ece3a437D5E224B17c156b16840AC7) | [Sourcify `exact_match`](https://repo.sourcify.dev/4663/0x9645388051ece3a437D5E224B17c156b16840AC7) |
| PartitioRouterV2 | [`0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA`](https://robinhoodchain.blockscout.com/address/0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA) | [Sourcify `exact_match`](https://repo.sourcify.dev/4663/0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA) |

Deployed from tag [`deploy-v2`](https://github.com/seekdaseek/partitio/tree/deploy-v2). Transactions,
gas, and every immutable read back from the chain: [docs/DEPLOYMENTS.md](docs/DEPLOYMENTS.md).

**Mainnet round trips**, September 28, 2026, from our demo wallet, which has never held ETH. The
first, at 14:00 UTC: [buy 1 USDG of AAPL](https://robinhoodchain.blockscout.com/tx/0x5f8d8c0eff1e5504c346511c7ce1d8cbad775f318cfc5e2ac521ed92ef8cdc56) ·
[sell it back](https://robinhoodchain.blockscout.com/tx/0x668e72767a4ff11981c523954641b8b0de43c1c301ee5cea043e8152918196b2).
The one in the demo video, at 15:30 UTC: [buy 0.99 USDG of AAPL](https://robinhoodchain.blockscout.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe) ·
[sell it back](https://robinhoodchain.blockscout.com/tx/0x2504a2e36d1ef0663e4750677dae2fd4b9f079d0727995620300b4507e326e2b). All four were sent, and their gas paid, by the
relayer. Details: [JUDGE_GUIDE.md](JUDGE_GUIDE.md#8-the-demo-trade).

## Run it

```shell
npm ci
forge test
```

`forge test` forks the public Robinhood Chain RPC at its latest block, so it needs no flags: 159
tests pass, and one v1 test is skipped with its reason printed. `script/review-run.sh` runs the same
suite pinned to a recent block.

```shell
node evidence/headline-offline.mjs
```

recomputes the headline from the committed snapshot, with no database and no RPC.

## How it was checked

- **An independent adversarial review** before any fix work, then a follow-up audit of the fixes, then
  a final hunter on the last unreviewed diff: [docs/REVIEW-2026-09-25.md](docs/REVIEW-2026-09-25.md),
  [docs/REVIEW-FIXES.md](docs/REVIEW-FIXES.md).
- **Every pre-deployment gate**, with the commit and test behind it: [docs/GO-REPORT.md](docs/GO-REPORT.md).
- **Medusa property fuzzing** of seven invariants: no funds at rest in the router or the entry, output
  never below minOut, each order executes once, the fee never above the signed maximum or the 0.50%
  cap, and aggregator fills always clear the Chainlink floor ([`test/fuzz/`](test/fuzz/)).
- **The whole relayer → contract path on a fork**, with real sends, before the first mainnet
  transaction: [`relayer/fork-e2e.mjs`](relayer/fork-e2e.mjs). Mainnet charged exactly the gas it measured.

## What it does not claim

- **Aggregator routes are not compared.** partitio compares its split with the best single committed
  pool. The contract allowlists Kyber's router, but the relayer builds no aggregator calldata in this
  version. "Best pool", not "best price anywhere".
- **The headline is quoted, not executed.** The split is priced from each venue's own quoter at each
  run's block. A fork test, `test_quotesMatchExecution`, checks that those quotes match executed fills
  within 5 bps, but the $100,000 figure describes what the contract does for anyone who calls it at
  that size, not trades our beta relayer has made.
- **The split is computed off-chain.** What is on-chain is the enforcement — venue proofs, the
  Chainlink floor and the signed minimum — which is the part that has to be trustless.
- **Two tickers are withheld.** GLD and RDDT are priced by feeds derived from the very pools a trade
  would move, so a Chainlink-style floor cannot guard them.

## Builder feedback

Five things Robinhood Chain, Paxos and Chainlink could change for the next builder, each measured
here and linked to its evidence: [docs/FEEDBACK.md](docs/FEEDBACK.md).

## Repository map

| path | what |
|---|---|
| `src/v2/` | `GaslessEntry`, `PartitioRouterV2`, `OracleGuard` — the deployed contracts |
| `relayer/` | quoting, the signing page, and the relayer that submits fills |
| `evidence/` | the measurement engine behind the headline, and its snapshot |
| `script/` | deploy inputs generated and verified on-chain, and the deploy script |
| `test/` | unit, review, hunt, fork and fuzz tests |
| `docs/` | review, fixes, gates, deployments, builder feedback, and the history-rewrite map |
