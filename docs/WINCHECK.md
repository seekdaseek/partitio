# WINCHECK — updated before submission

Nine questions a judge will actually ask, and where the answer lives. A row is only "done" when it
points at something executable.

| # | question | answer | state |
|---|---|---|---|
| 1 | Is it deployed on an Arbitrum chain? | Robinhood Chain (4663), an Orbit chain. Router, caller and Stylus module live — `docs/DEPLOYMENTS.md` | **done** |
| 2 | Does it actually work? | 3 live mainnet swaps through a contract, AAPL round trip at 10.0 bps — `docs/DEPLOYMENTS.md` | **done** |
| 3 | Is the problem real and measured? | 68 Morpho markets, 48k feed samples, 32k addresses classified, 16k+ engine quotes — `docs/PROBLEM.md`, `docs/GATES.md` | **done** |
| 4 | Can a judge verify it in five minutes? | `docs/JUDGE_GUIDE.md` — explorer links, tx hashes, a keyless `eth_call` curl, the test command, CSV export | **TODO** |
| 5 | Has anyone but the team used it? | public beta from Sep 28, $50/trade cap + per-address daily cap. Distinct non-team wallets counted separately; our own demo trades labelled as ours | **TODO** |
| 6 | Is the contract any good? | Slither on every contract; Echidna/Medusa property fuzzing of GaslessEntry + router invariants. Findings fixed or justified in `docs/SECURITY.md`. Tools named in the README only if they actually ran | **TODO** |
| 7 | Does it use the sponsors' tech? | Robinhood Chain, Paxos USDG (EIP-3009 + EIP-2612, proven), Uniswap v3/v4, Stylus. QuickNode and Trail of Bits tooling listed only once actually in the running code | partial |
| 8 | Will it still be up when results land? | App, relayer, engine and quote endpoint up through **Oct 25** (Founder House). QuickNode trial ends ~Oct 24 → automatic fallback to publicnode/canonical. Relayer float self-refills from USDG fees; if it runs dry the app degrades to "quotes only, trading paused" with a banner — never to down | **TODO** |
| 9 | Is the evidence real and continuous? | One unbroken series from now: every relayer `/quote` and every engine comparison is a timestamped paired sample. Target ≥5 digits over ≥6 days by Sep 30. No resets | running |

## Evidence counter

The v1 series (5 runs, 22,272 quotes) is retained but is **not** part of the headline count — it
measured only the sell side. The headline count runs from engine v2 onward, one continuous series.
