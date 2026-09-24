# PROBLEM — measured, 2026-09-24

Chain 4663, block ~71.4M. Morpho Blue `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`
(from `/opt/bid-sampler/bid-markets.json`, confirmed by reading 31,167 bytes of code and
`owner()` = `0x060595638692de6CCd47ca04094F1772D3D39728`).

Method: every `CreateMarket` and `Liquidate` event over the full chain history via `eth_getLogs`
on the canonical RPC. Market ids were re-derived as `keccak256(abi.encode(marketParams))` and
**asserted against the indexed id in each log** — 278 of 278 matched, 0 mismatches — before any of
it was trusted. State from `market(bytes32)`, prices from each market's own `oracle.price()`.

## Scale

| | |
|---|---|
| USDG total supply | **683,367,081 USDG** |
| Steakhouse USDG vault `0xBeEff0…09dd` | **495,886,170 USDG** in `totalAssets()` |
| Markets created on Morpho 4663 | 278 |
| Stock-collateral markets with a USDG loan | 68 live (supply > 0) |
| Their total supply | **878,986 USDG** |
| Their total borrow | **5,966 USDG** |
| Utilisation of stock-collateral markets | **0.68%** |
| Stock-collateral borrow as a share of the vault | **0.0012%** |

Oracle scale verified: the AAPL oracle returns `336028886140247377736003759`, which at Morpho's
`1e36 * 10^(loanDec - collDec)` = `1e24` is **336.02 USDG**, against a live v3 quote of 336.49 for
1 AAPL — 0.14% apart. The oracles are sane and usable as the exit-cost denominator.

## Every stock-collateral market that has borrow

| ticker | LLTV | break-even | supply USDG | borrow USDG |
|---|---|---|---|---|
| SPY | 62.5% | 11.25% | 11,227.77 | **4,342.65** |
| NVDA | 62.5% | 11.25% | 173,792.72 | **902.04** |
| NVDA | 62.5% | 11.25% | 6,578.67 | 417.10 |
| SPCX | 62.5% | 11.25% | 279,954.93 | 114.12 |
| MSTR | 62.5% | 11.25% | 100.00 | 66.00 |
| COIN | 62.5% | 11.25% | 110.00 | 50.00 |
| PLTR | 62.5% | 11.25% | 30.00 | 30.00 |
| TSLA | 77.0% | 6.90% | 15.01 | 11.89 |
| …24 more | | | | all below 6 USDG |

Break-even is the liquidator's exit budget, `0.3 * (1 - LLTV)` uncapped, from Morpho Blue's
`LIF = min(1.15, 1/(1 - 0.3*(1 - LLTV)))`.

## Liquidation history

**225 `Liquidate` events on Morpho 4663. Four of them touched stock collateral.**

| collateral | LLTV | count | repaid | seized | bad debt | callers |
|---|---|---|---|---|---|---|
| SGOV | 91.5% | 1 | 8.76 USDG | 0.089312 | **0** | 1 |
| NVDA | 62.5% | 2 | 6.67 USDG | 0.035742 | **0** | 2 |
| SPCX | 38.5% | 1 | 20.67 USDG | 0.177602 | **0** | 1 |

Every one succeeded. Zero bad debt. The largest repaid 20.67 USDG.

## Exit cost, measured against each market's oracle, $500k sell into USDG

Engine v1, most recent completed run. Cost is versus the oracle mark, so it is slippage, not a
pool quoting itself.

| ticker | best single venue | partitio split | market break-even | borrow in that market |
|---|---|---|---|---|
| AAPL | **−15.26%** | **−1.70%** | 11.25% | 1.00 USDG |
| GOOGL | **−18.51%** | **−1.31%** | 11.25% | 1.00 USDG |
| TSLA | −4.80% | −0.95% | 6.90% / 11.25% | 11.89 USDG |
| **SPY** | **−0.56%** | **−0.21%** | 11.25% | **4,342.65 USDG** |
| **NVDA** | **−0.23%** | **−0.18%** | 11.25% | **902.04 USDG** |

## The thesis does not survive this

The planned headline says lenders cannot take stock collateral because a $500k liquidation loses
more than its margin. Three measurements contradict it:

1. **No position of that size exists.** The largest stock borrow on the chain is SPY at 4,342.65
   USDG. A $500k liquidation is roughly **115× the entire stock-collateral borrow of the chain**,
   and ~115× the largest single market. The scenario is hypothetical by two orders of magnitude.

2. **The markets that are actually used have no exit problem.** SPY and NVDA hold 88% of all stock
   borrow, and both exit at **−0.21% and −0.18%** through partitio at $500k — against an 11.25%
   break-even. Even the *best single venue*, with no routing at all, costs 0.56% and 0.23%. At the
   real liquidation size (~4,343 USDG for the largest) the cost rounds to zero. The margin of
   safety is **~50×**, not a breach.

3. **The 4.2% figure belongs to markets nobody uses.** Break-even of 4.2% is the 86% LLTV markets.
   AAPL at 86% holds 0.09 USDG of supply and 0.08 USDG of borrow. The markets with real borrow are
   62.5% LLTV, where break-even is 11.25% — and nothing measured comes close to breaching it.

Where the routing gain is real — AAPL −15.26% → −1.70%, GOOGL −18.51% → −1.31% — those markets
hold **1.00 USDG of borrow each**. The gain is genuine and large; the demand for it is not there
today.

## What is true and defensible

- **495.9M USDG of lending capital sits on this chain and 5,966 USDG of it is lent against stock
  collateral.** That is a real, measured, enormous gap, and it is the honest headline.
- **Exit cost at size is measurable, and for the thin names it is severe**: a $500k AAPL sell
  through the best single pool loses 15.26%, and routing recovers 13.6 points of that. That is a
  real capability whether or not a lender is using it today.
- **Nothing in the data shows a liquidation failing.** Claiming otherwise would be inventing a
  failure that has not happened, at a size that does not exist.

Stated plainly rather than framed around: partitio is demonstrably better routing for tokenized
stocks at size. It is **not** demonstrably the fix for a liquidation crisis, because there is no
liquidation crisis in the data.
