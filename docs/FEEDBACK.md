# Builder feedback — Robinhood Chain, Paxos, Chainlink

Five things we ran into while building partitio on Robinhood Chain (4663), September 24–28, 2026.
Each one was measured in this repository, and its evidence path is given with it.

## Robinhood Chain

### 1. The explorer name a builder guesses drops the transaction

`explorer.mainnet.chain.robinhood.com/tx/<hash>` does not show the transaction: it redirects to
Blockscout's home page and drops the path. Our page linked every fill there, and the first mainnet
trades on September 28 opened the home page instead of the transaction. To reproduce:

```shell
curl -sI http://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe
```

answers `301` with `Location: https://robinhoodchain.blockscout.com/`. Every link partitio shows now
goes to `robinhoodchain.blockscout.com/tx/<hash>` directly.

**Evidence:** `relayer/public/partitio-index.html` (the `EXPLORER` constant and its comment), commit
`bade27a`.
**What would help:** a redirect that keeps the path, or the chain's docs naming Blockscout as the
explorer.

### 2. IONQ and RKLB traded far below their feeds, for days

The committed pools for these two stocks sat well below their Chainlink feeds on both days we
measured: about 11.7% (IONQ) and 6.3% (RKLB) below on September 25, and 12.07% and 5.19% below at
the deploy-input check on September 27. On the 27th, selling one IONQ share into its only committed pool
would have paid about $0.29 against a feed near $45. partitio's floor refuses those sells. A router
without one would fill them.

**Evidence:** `relayer/server.mjs` (the sell-pause comment, commit `7c2b3b7`, 2026-09-25);
`docs/GO-REPORT.md` and `script/predeploy-bindings.mjs` (the recorded gap, commit `677358d`,
2026-09-27); `JUDGE_GUIDE.md`, claims 1–2.
**What would help:** a signal builders can read when a listed stock's pools drift from its feed, or
liquidity support for the thinnest listings.

### 3. 0x does not route stock tokens on 4663

0x's API supports chain 4663 and priced USDG↔WETH, but answered every stock token we asked for
(USDG→AAPL, AAPL→USDG, USDG→SPY) with `422` `BUY_TOKEN_NOT_AUTHORIZED_FOR_TRADE` /
`SELL_TOKEN_NOT_AUTHORIZED_FOR_TRADE`: "not authorized for trade due to legal restrictions". The
answer was the same from Moldova and from Germany. Tested 2026-09-24 with a live API key.

**Evidence:** `docs/GATES.md` (Aggregator coverage), `evidence/collect2.mjs` (`ZEROX_REFUSES_STOCKS`).
**What would help:** a list in the chain's docs of which aggregators may route stock tokens, before
a builder integrates one.

## Paxos

### 4. USDG's balance error decodes as unknown

A USDG transfer above the balance reverts with USDG's own `InsufficientFunds()` (`0x356680b7`), which
carries no arguments. AAPL, on the same chain, reports the same failure with OpenZeppelin's
ERC-6093 `ERC20InsufficientBalance(sender, balance, needed)`. A decoder built on the standard ERC-20 errors,
as our relayer's was, shows `unknown (0x356680b7)`, and that is what Sergiu saw after signing a buy
of 1 USDG with 0.996536 in the wallet (2026-09-28, 14:08 UTC). An `eth_call` transfer of 1 USDG
from that wallet reverts with `0x356680b7`; 0.99 goes through.

**Evidence:** `docs/DEPLOYMENTS.md` (Mainnet trades), `relayer/submit.mjs` (`errorAbi` and its
comment), `relayer/submit.test.mjs`.
**What would help:** the ERC-6093 error, with the balance and the amount, which every standard
decoder already names.

## Chainlink

### 5. GLD and RDDT are priced by pool prices, not Chainlink feeds

Of the 37 feeds recorded for Robinhood Chain stock tokens, 35 are Robinhood-named feeds with 8
decimals. The two for GLD and RDDT describe themselves as "Uniswap V3 Pool Price in USD" and answer
with 18 decimals, and they are the only feeds we saw reporting `updatedAt` ahead of the chain
clock. A pool price cannot guard a trade that moves that same pool, so partitio withholds both
tickers. To reproduce:

```shell
cast call 0x9d380f2988fe04c58a69c3c5dc389b8587c76012 "description()(string)" --rpc-url https://rpc.mainnet.chain.robinhood.com
cast call 0x3ff171e03b47e20ac279d75642cea05471d43fb4 "decimals()(uint8)" --rpc-url https://rpc.mainnet.chain.robinhood.com
```

**Evidence:** `relayer/chainlink-feeds.json`, `docs/GATES.md` (Chainlink feeds, item 2),
`docs/ORACLE-GUARD.md` (§4), `script/predeploy-bindings.mjs` (`HIDDEN`).
**What would help:** Chainlink feeds for GLD and RDDT on 4663, or a label wherever a feed in these
markets is not one.
