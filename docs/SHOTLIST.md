# Demo video — shot list

Recording: **Monday, September 28, 2026, from 16:30 Chisinau** (09:30 New York, the US open), so the
Chainlink feeds are minutes old rather than two days old and the page shows no "market closed" tag.
Target length **2:45**. One continuous screen recording, voice-over added after.

## Pre-flight, 15 minutes before

| check | how | pass |
|---|---|---|
| relayer is live | `https://partitio.ochinimus.app/api/health` | `trading: true`, `floatEth` ≥ 0.0003 |
| demo wallet funded | `0x0032fB2549Eeb8f6E41106c595d5B1b99bBB7554`, funded by the sweep in block 74213677 | **0.996536 USDG** after the first round trip on September 28, **0 ETH**, nonce 0, no code |
| wallet labelled as ours | in `PARTITIO_TEAM_ADDRESSES` on the relayer | done 2026-09-27; the fill reports `isTeam: true` |
| market open | the app's Chainlink badge | no "market closed" tag, feed minutes old |
| AAPL is inside the band | the app at `?amt=0.99` | green badge; if not, use NVDA or SPY |
| the refusal still shows | the app at `?t=IONQ&side=sell&amt=1` | red badge; if IONQ recovered, find another red sell to show |
| browser | dark mode, 1440×900 window, zoom 110%, bookmarks bar hidden, notifications off | — |

Tabs open, in this order: the app at `/?amt=100000` · the app at `/?t=IONQ&side=sell&amt=1` · the app
at `/?amt=0.99` · Sourcify for GaslessEntry · a terminal in a fresh clone of the repo. Blockscout opens
from the link in the **Filled** receipt, so it needs no tab of its own.

## Shots

| # | time | on screen | voice-over |
|---|---|---|---|
| 1 | 0:00–0:12 | top of the page: H1 and the headline line | "A $100,000 stock-token order on Robinhood Chain sent to the best single pool left a median $199 on the table, in 6,329 of 7,493 executable quotes." |
| 2 | 0:12–0:35 | `?amt=100000`, no wallet: the three-colour route bar, "vs the best single pool", "you keep … after the fee" | "partitio quotes every committed pool and splits the order only when the split beats the best one. Here it beats the best pool alone, and you keep the gain after the fee." (read the dollar figure off the screen) |
| 3 | 0:35–0:52 | the green Chainlink badge with the feed age; then the IONQ tab, red badge | "Every fill is checked against Chainlink inside the contract. The only IONQ pool would pay a fraction of the Chainlink price. partitio refuses it." |
| 4 | 0:52–1:05 | the `/?amt=0.99` tab, Connect: "You hold 0.9965 USDG · 0 AAPL · 0 ETH — and you don't need any" | "This wallet holds under a dollar of USDG, and no ETH at all." |
| 5 | 1:05–1:40 | Review & sign; wallet prompt 1, the order, pausing on minOut and the fee cap; prompt 2, the USDG authorization; "Filling on-chain…"; the green **Filled** receipt with the transaction link, which stays until the next click | "Two signatures: the order, and an authorization for exactly this order's USDG. No transaction from my wallet. A relayer submits it and pays the gas." |
| 6 | 1:40–1:55 | click the receipt's link: Blockscout shows the transaction sent by the relayer `0x8155…2216` to GaslessEntry, gas paid by it; back on the page, the wallet still at 0 ETH | "The transaction comes from the relayer. My wallet still has no ETH." |
| 7 | 1:55–2:20 | Sell: the box fills with the whole AAPL balance; Review & sign, the permit prompt, the **Filled** receipt | "Selling back is the same: a permit instead of a transfer, and the fee comes out of the USDG proceeds." |
| 8 | 2:20–2:38 | Sourcify `exact_match` for GaslessEntry; the terminal running `node evidence/headline-offline.mjs` to the $100,000 row | "The contracts are ownerless, immutable and verified. The headline recomputes from the committed data, with no server." |
| 9 | 2:38–2:45 | the page with its URL, and the GitHub URL | "partitio. Never worse than the best pool." |

## If something goes wrong on camera

- **A badge turns amber or red on AAPL**: switch the ticker to NVDA or SPY; the refusal itself is a
  feature, and shot 3 already shows one.
- **A fill is refused**: the page names the reason and nothing is spent. Re-quote and sign again.
- **The button reads "Not enough USDG, you hold …"**: the box holds more than the wallet. Press Max,
  or type 0.99. Nothing can be signed until the amount fits.
- **The quote is slow**: wait for the route bar; do not click Review before it appears.

## After recording

1. Copy the buy and sell transaction hashes from the two **Filled** receipts, or the relayer log.
2. Add them to `JUDGE_GUIDE.md` section 8 and the README as `https://robinhoodchain.blockscout.com/tx/<hash>` links, open
   both, then commit and push.
3. Upload the video and add its link to `docs/HACKQUEST.md`.
