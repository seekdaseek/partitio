# Judge guide — verify every claim in five minutes

Every claim partitio makes, and the fastest way to check it yourself. Nothing here asks you to trust
us: each check reads the chain, a public verifier, or code you run.

| # | claim | check | time |
|---|---|---|---|
| 1 | The split beats the best single pool at size, live | open [partitio.ochinimus.app/?amt=100000](https://partitio.ochinimus.app/?amt=100000) — no wallet needed | 20 s |
| 2 | Every fill is checked against Chainlink, and a bad price is refused | same page: the **Chainlink check** badge; for a refusal, open [sell 1 IONQ](https://partitio.ochinimus.app/?t=IONQ&side=sell&amt=1) | 20 s |
| 3 | The contracts are verified source | Sourcify: [GaslessEntry](https://repo.sourcify.dev/4663/0x9645388051ece3a437D5E224B17c156b16840AC7) · [PartitioRouterV2](https://repo.sourcify.dev/4663/0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA) — both `exact_match` | 30 s |
| 4 | The live app uses exactly those contracts | [partitio.ochinimus.app/api/health](https://partitio.ochinimus.app/api/health) → `contracts` | 10 s |
| 5 | Ownerless and immutable | in the verified source: no `Ownable`, no `onlyOwner`, no admin function, no proxy, no `selfdestruct`, no `delegatecall` | 60 s |
| 6 | The tests pass | `git clone https://github.com/seekdaseek/partitio && cd partitio && npm ci && forge test` → 159 passed, 1 skipped with its reason | ~3 min |
| 7 | The headline number | `node evidence/headline-offline.mjs` → the `$100000` row | 10 s |
| 8 | A real trade, with no ETH in the wallet | the demo buy and sell below, on Blockscout | 30 s |

## 1–2. The live quote

The page quotes without a wallet, above the $50 beta cap, so any size can be tried. What to look
for at $100,000 of AAPL: the route bar split across several venues, **"vs the best single pool"**
with the dollar gain and **"you keep … after the fee"**, and the **Chainlink check** badge. Green is
inside the band, amber is close to it, red means the contract would refuse the fill. A sell of one
IONQ shows red: the only committed IONQ pool is nearly empty, and on September 27 it would have paid
about $0.29 for a share Chainlink prices near $45. A router without a floor would take that fill;
partitio's contract reverts instead. The exact figure moves with the pool; the refusal is the point.
The button stays capped: "beta: $50 per trade".

## 3–5. The contracts

| contract | address | deploy tx |
|---|---|---|
| GaslessEntry | [`0x9645388051ece3a437D5E224B17c156b16840AC7`](https://robinhoodchain.blockscout.com/address/0x9645388051ece3a437D5E224B17c156b16840AC7) | [`0xb4539d6c9488350abb899ef1a8f2aae46383bdc77391ac7e9eb9993447060f7a`](https://robinhoodchain.blockscout.com/tx/0xb4539d6c9488350abb899ef1a8f2aae46383bdc77391ac7e9eb9993447060f7a) |
| PartitioRouterV2 | [`0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA`](https://robinhoodchain.blockscout.com/address/0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA) | [`0x12c7363910f26e7b5fe9c8f2e208fb38cbfc493bf66872e2dc67ca4048a4923c`](https://robinhoodchain.blockscout.com/tx/0x12c7363910f26e7b5fe9c8f2e208fb38cbfc493bf66872e2dc67ca4048a4923c) |

Both were built from the tag [`deploy-v2`](https://github.com/seekdaseek/partitio/tree/deploy-v2).
Searching the source for "owner", "pause" or "sweep" finds only comments explaining why each is
absent, and, in `GaslessEntry`, the `owner` field of a signed order: the user who signed it.
Sourcify's `exact_match` means the published source and compiler settings reproduce the deployed
bytecode byte for byte, metadata included. To read an immutable yourself, with Foundry installed:

```shell
cast call 0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA "VENUE_ROOT()(bytes32)" --rpc-url https://rpc.mainnet.chain.robinhood.com
```

It returns `0x479225b5355fa32c3695106a2d164ab0b04f943a5d6c9c6bd28a85f35a914fc2`, the Merkle root of
the 161 committed venues listed in [`relayer/venues.json`](relayer/venues.json).

## 6. The tests

`forge test` forks the public Robinhood Chain RPC at its latest block (configured in `foundry.toml`),
so it needs no flags and no keys. Expect **159 passed, 0 failed, 1 skipped**. The skipped test
measures the older v1 router's on-chain split at $500k, which depends on the day's pool state; it
prints its reason and runs with `PARTITIO_RUN_V1_I8=1`. Because the fork is at the latest block,
market-dependent tests reflect the market at the moment you run them.

## 7. The headline

> A $100,000 stock-token order on Robinhood Chain sent to the best single pool left a median $199
> on the table in 6,329 of 7,493 executable quotes. partitio splits it and floors the fill against
> Chainlink.

Quoted, not executed · the beta caps trades at $50 · runs 1–245, Sep 24–27, 2026.

`node evidence/headline-offline.mjs` recomputes it from [`evidence/snapshot-runs-1-245/`](evidence/snapshot-runs-1-245/)
— every quote row the collector recorded and the Chainlink answer at each run's own block — with no
database and no RPC. It repeats the server-side query, [`evidence/headline.mjs`](evidence/headline.mjs),
integer for integer. The rules it applies, so you can judge them rather than the number:

- **Executable only.** A row counts if its quote ladder is complete and the better route sits inside
  the 2% Chainlink band the app signs. A gain on a trade the contract would refuse is not a gain.
- **Per trade, never summed.** Summing across runs would count the same thin pool once per snapshot.
- **Biased against us.** On a buy, the extra stock is valued at the split's own, lower price.

## 8. The demo trade

The first mainnet round trip, Monday, September 28, 2026, from our demo wallet
[`0x0032fB2549Eeb8f6E41106c595d5B1b99bBB7554`](https://robinhoodchain.blockscout.com/address/0x0032fB2549Eeb8f6E41106c595d5B1b99bBB7554),
which has never held ETH: its balance is 0 ETH and its nonce is 0, before and after. Both
transactions were sent, and their gas paid, by the relayer
[`0x8155Fe3D74e5D97DC3E6dE119c497A24Aca62216`](https://robinhoodchain.blockscout.com/address/0x8155Fe3D74e5D97DC3E6dE119c497A24Aca62216).
The relayer counts the demo wallet's orders as ours, not as users'.

| step | tx | block | in | out | fee | gas, paid by the relayer |
|---|---|---|---|---|---|---|
| buy AAPL | [`0x5f8d8c0e…8cdc56`](https://robinhoodchain.blockscout.com/tx/0x5f8d8c0eff1e5504c346511c7ce1d8cbad775f318cfc5e2ac521ed92ef8cdc56) | 74852093 | 1 USDG | 0.002905609090167306 AAPL | 0.005 USDG | 585,512 |
| sell it back | [`0x668e7276…8196b2`](https://robinhoodchain.blockscout.com/tx/0x668e72767a4ff11981c523954641b8b0de43c1c301ee5cea043e8152918196b2) | 74852963 | 0.002905609090167306 AAPL | 0.990099 USDG | 0.004947 USDG | 610,871 |

On Blockscout each transaction goes **from the relayer to GaslessEntry**, and the wallet's tokens
move inside it on signatures alone: USDG's EIP-3009 authorization on the buy, the stock's EIP-2612
permit on the sell. The fee goes to the relayer in USDG. The recorded demo repeats this round trip
with 0.99 USDG; its transactions are added here once they exist.

---

What partitio does **not** claim is listed in the [README](README.md#what-it-does-not-claim).
