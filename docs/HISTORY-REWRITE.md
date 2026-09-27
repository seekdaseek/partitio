# History rewrite — 2026-09-27

Before the first public push, two paths were removed from every commit on `main` and from the
`deploy-v2` tag with `git filter-repo`:

- `stylus/partitio-math/target/` — Rust build output, 873 MB across 2,105 blobs, committed by accident
- `.venv-sec/` — a Python virtualenv for the Slither tooling, 76 MB across 4,388 blobs

Neither contained a secret (full-history gitleaks plus an exact-match hunt for every real key this
project uses both came back clean). They were removed because they were 97% of the repository
and none of it was source. Every commit hash changed as a result. Commit messages were updated by
filter-repo; hashes quoted inside tracked files - the docs, two test comments and the broadcast
record's `commit` field - were updated from this map. Hashes quoted anywhere else before
2026-09-27 resolve through it.

The deployed contracts are unaffected: their source is verified on Sourcify by bytecode and
metadata, not by git hash. `deploy-v2` moved from `ea6f70b` to `8698a5e`.

| before | after | subject |
|---|---|---|
| `0386173` | `2209cd1` | B1: PartitioRouterV2 - ownerless, Merkle venues, both directions, measured guard |
| `039a577` | `11d2f50` | The trading page, and send wired behind an explicit switch |
| `04ddb2b` | `c43f223` | Final contract batch: maxFeedAge, minOut > 0, viem, and the 4f answers |
| `0963b7f` | `185e97a` | Close r01-spent-donation with a test, and 16 tests whose prank was swallowed |
| `0ca9b34` | `4cc409f` | label 0x accurately in the engine: asset-class-refused, not no-api-key |
| `0e4b72d` | `06b0c45` | gasless sell, permit front-run, aggregator under-delivery - and three real bugs |
| `1571413` | `225c225` | Judge residuals: the dead store in the H-1 fix, and two tests that proved nothing |
| `19d9fee` | `a720790` | P0 gates G5-G6 pass; venue map found materially incomplete |
| `2d622b3` | `677358d` | Deploy inputs, generated and verified on-chain: venue root, feed map, allowlist |
| `2eb437c` | `980c30c` | Chunk the evidence collector's RPC batches at 25 |
| `3288abe` | `bd5e4a1` | engine v2: LI.FI instrumented, 0x wired but inert pending an API key |
| `3886648` | `3288713` | Fix every open review finding, plus 12 the follow-up audit found in the fix itself |
| `3c284b6` | `37a66f8` | Pre-deploy check 4a: every token -> feed binding verified on-chain |
| `517124e` | `aec6c00` | Deployed: PartitioRouterV2 and GaslessEntry on Robinhood Chain 4663 |
| `5922877` | `fd1444e` | GO report: every gate, and how each OPEN and PARTIAL was resolved |
| `59d6e62` | `e5d1d5c` | correction 6: drop the flaky quote-differ test, add honest fork pinning |
| `64263b5` | `a1f49e9` | 0x refusal is not geographic; add a 120h dead-feed ceiling |
| `673b75c` | `7e7a096` | oracle guard designed from 48k feed samples |
| `6dd6838` | `9161b61` | Close the coverage and assertion gaps the re-verification found |
| `75b6c43` | `02eae0d` | R-12 tests: denominate the fee in USDG |
| `78ac1aa` | `5e40897` | P1: PartitioRouter + PartitioCaller, 9 acceptance tests pass on fork |
| `7c5975d` | `1ff6c39` | G3: engine v2 live - both directions, classified Kyber responses |
| `7f67ba6` | `cceeb08` | Hunter on the unreviewed diff: no HIGH, no MEDIUM, and three corrections to my own claims |
| `829d53a` | `7c2b3b7` | Relayer submit endpoint: validate, re-quote, simulate, and only then send |
| `84cbe18` | `058a002` | Re-judge the OPEN items: three tests that would have passed either way |
| `850722d` | `2c91d47` | Two design directions, v2: the desk and the number |
| `8b0b541` | `275343f` | Slither triage of the final src, and the coverage situation stated plainly |
| `94dfffb` | `d112f88` | corrections: void kipseli baseline, fix getLogs claim, prove propAMM settlement |
| `95add4f` | `63d29fc` | Shared order module: one copy of the format, and legs that sum to spendable |
| `9da541d` | `7ec022c` | registry: 587 venues verified on-chain from 3,315 log-discovered candidates |
| `a3540a8` | `d55d720` | Fix record: disposition of every finding, and the ones the fixes created |
| `a3a4a2f` | `60c9a58` | stylus: PartitioMath deployed and activated on mainnet, gas table measured |
| `a648223` | `efed135` | Relayer key: generated on the box, 0600, address-only output |
| `a82984d` | `4ed66a1` | G2: 46% of addresses touching stock tokens cannot pay for one swap |
| `a8e6fa2` | `09cdf01` | Measure the 2% default band before shipping it: it refuses on size, not on ticker |
| `aab61a7` | `2be95ef` | P0 gates G2-G4: verified Uniswap/Morpho/Rialto addresses, venue map of 233 pools |
| `ac69dc8` | `a3e8e23` | Stylus honesty: the split is computed off-chain, and say so everywhere |
| `b507c6c` | `8db0239` | Record what the fuzz call count actually means, and the two coverage gaps |
| `b76ddbd` | `e303882` | 0x will not quote tokenized stocks on 4663 - key left unused |
| `b91976c` | `2524705` | Review addendum: SGOV measurement settles the uiMultiplier convention |
| `bae3b52` | `7913002` | P0: problem measured - and it contradicts the planned thesis |
| `bcb83b0` | `b7a7335` | Fee = gas of the route + 20% of savings; a quote without a wallet; colour; price-first |
| `bfde1de` | `2a518a0` | I8 proven on executed output; up-v3 enumeration solved |
| `c1f33af` | `3ca3708` | Prove every committed venue settles through the deployed router |
| `d11ad43` | `c4c18d1` | Close the hunters' HIGH: an accepted aggregator sliver no longer ends the fill |
| `d3a6a0e` | `96fdee3` | A fresh clone runs green with plain `forge test`; v1's I8 skips with its reason |
| `d6767d8` | `29cc500` | Open at $50, the largest tradeable size, and fix the status pill's double gap |
| `d89f69f` | `dfb0a51` | oracle audit: no live misconfiguration; correct my own CRWV claim |
| `dc842d7` | `ba43fa2` | Record the fork run against the deployed contracts: 0 failures |
| `ddf5cc6` | `e64287d` | mainnet: router and caller deployed, three live swaps settled |
| `dfa15b2` | `68948c0` | evidence engine v0 live on VPS as partitio-evidence |
| `e326d52` | `3ab1646` | G1 addenda proved; G2 corrected - the 40.4% figure was wrong and is withdrawn |
| `e8bd942` | `3aa738f` | correct the EntryPoint call, record delegate identities, lock positioning |
| `ea6f70b` | `8698a5e` | Fail loudly when the revert decoder has no artifacts |
| `ef15927` | `e1e2e34` | B2: GaslessEntry - one signature, no ETH, aggregator leg with same-tx fallback |
| `eff64d9` | `c9a9a78` | The relayer's send path, and the first broadcast it ever made - on a fork |
| `f3cd1a7` | `4259a36` | add WINCHECK.md: nine judge questions, four still open |
| `f402b88` | `b8be79c` | B3: relayer quotes all four sources, with two bugs fixed in the first smoke test |
| `f8e5df6` | `ac654de` | G1 PASS: USDG has EIP-3009 + EIP-2612, stock tokens have permit |
| `fc51b58` | `1cf7d6c` | Merge the independent review's tests, report and fuzz harness |
