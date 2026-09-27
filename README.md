# partitio

Tokenized stocks on Robinhood Chain at the best single pool's price or better: an order is split
across committed venues only when the split beats the best single pool, every fill is floored
against Chainlink inside the contract, and the user needs no ETH — a relayer pays the gas.

**Live:** https://partitio.ochinimus.app — quotes work without a wallet; trading is a public beta
capped at $50 per trade.

## Contracts — Robinhood Chain (4663), ownerless and immutable

| contract | address | source |
|---|---|---|
| PartitioRouterV2 | `0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA` | Sourcify `exact_match` |
| GaslessEntry | `0x9645388051ece3a437D5E224B17c156b16840AC7` | Sourcify `exact_match` |

Deployed from tag `deploy-v2`. Transactions, gas and read-back checks: [docs/DEPLOYMENTS.md](docs/DEPLOYMENTS.md).

## Run the tests

```shell
npm ci
forge test
```

`forge test` forks the public Robinhood Chain RPC at its latest block (set in `foundry.toml`), so no
flags are needed. One v1 test is skipped by default and says why in its output.

## Where things are

- [docs/GO-REPORT.md](docs/GO-REPORT.md) — every pre-deployment gate, with the commit and test behind it
- [docs/REVIEW-2026-09-25.md](docs/REVIEW-2026-09-25.md), [docs/REVIEW-FIXES.md](docs/REVIEW-FIXES.md) — the independent review and the disposition of every finding
- `src/v2/` — the contracts; `relayer/` — quoting, the signing page and the relayer; `evidence/` — the measurement engine

The full README, with the measured headline, follows.
