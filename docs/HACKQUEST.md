HACKQUEST SUBMISSION - partitio

Paste each answer exactly as written. Every answer is plain sentences with no markdown, no em
dashes, no parentheses and no underscores. The submission fields are each under 300 characters;
the project page fields run longer. The project has existed on HackQuest since
September 27, 2026, editor at projects/setup/5c822f6e-afad-454f-adb5-cc7d2e6ea625, and Sergiu
connected the payout wallet on September 28. Fill the fields below in that editor.
The project was submitted on September 28, 2026, to the Overall Prize, Promising Products and Grants
tracks; the dashboard keeps it editable through Edit Submission until the deadline.

========================================================================
PROJECT PAGE - the HackQuest project page fields, pasted word for word
========================================================================

PROJECT NAME
partitio

INTRO
Tokenized stocks on Robinhood Chain at the best single pool's price or better, floored against Chainlink, and no ETH needed to trade.

DESCRIPTION
A $100,000 stock-token order on Robinhood Chain sent to the best single pool left a median $199 on the table in 6,329 of 7,493 executable quotes. partitio splits it and floors the fill against Chainlink. Those are quotes, not executions, from runs 1 to 245 between September 24 and 27, 2026, and they recompute offline from the repo.

partitio quotes every committed pool for a stock and splits the order only when that beats the best single pool. The contract checks every fill against Chainlink and reverts outside the band. Users sign twice and hold no ETH, because a relayer pays the gas: buys are funded by USDG's EIP-3009 authorization, sells by the stock token's EIP-2612 permit.

It is live on Robinhood Chain mainnet. The router commits to 161 venues across Uniswap v3, Uniswap v4 and maker pairs by an immutable Merkle root, and binds 35 tokens to their Chainlink feeds. Both contracts are ownerless and verified on Sourcify. Two round trips have filled on mainnet from a demo wallet that has never held ETH, and the demo video shows the second.

Every claim can be checked in five minutes with the judge guide at the top of the repo. The beta caps trades at $50, and aggregator routes are not compared.

PROGRESS DURING BUILDATHON
Everything here was built during the buildathon, starting with the first commit on September 24, 2026.

September 24 to 27: an evidence engine that quotes 18 stock tokens at four sizes about every 20 minutes, on-chain, venue by venue. Runs 1 to 245 produced 34,562 quote rows and 4,392 Chainlink references. An independent review of the contracts found 12 issues, one critical and one high. Both were fixed, and all 12 were closed before deployment. A follow-up audit of the fixes found 12 more, and the deploy went out with nothing high or critical open. 159 Foundry tests pass, and Medusa fuzzing ran with 0 failures.

September 27: PartitioRouterV2 and GaslessEntry deployed on Robinhood Chain mainnet, exact match on Sourcify, and the relayer went live at partitio.ochinimus.app.

September 28: two mainnet round trips, AAPL bought with USDG and sold back, from a wallet that has never held ETH. A builder feedback file in the repo records five issues we hit on Robinhood Chain, Paxos USDG and the price feeds, each with its evidence.

FUNDRAISING STATUS
Not raising. Self-funded, and entering the Grants track for milestone funding.

TECH STACK
Solidity, Node, Foundry, OpenZeppelin, Chainlink, Uniswap, USDG, Robinhood Chain

PRODUCT CATEGORY
DeFi, RWA, Infra

TEAM INTRO - on the Team tab
I am Sergiu O, a solo builder shipping under ochinimus. I have shipped on Solana, Base, Algorand, X Layer, Stellar and now Robinhood Chain: a paid x402 market data API, trading tools and apps for the Solana Seeker phone. partitio was built during this buildathon, from the first commit on September 24 to the mainnet deploy on September 27. Previous wins: LineWatch took 2nd of 182 in the TxODDS Trading Tools and Agents track, and docket won Best Use of HydraDB.

========================================================================
SUBMISSION FIELDS
========================================================================

CONTRACT ADDRESS
0x9645388051ece3a437D5E224B17c156b16840AC7

PRIZE TRACKS
Overall Prize, Promising Products Track, Grants

LINK TO THE FRONTEND
https://partitio.ochinimus.app

CORE PROTOCOL ADDRESSES
GaslessEntry 0x9645388051ece3a437D5E224B17c156b16840AC7, verified at https://repo.sourcify.dev/4663/0x9645388051ece3a437D5E224B17c156b16840AC7. PartitioRouterV2 0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA, verified at https://repo.sourcify.dev/4663/0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA.

FACTORY OR POOL CONTRACTS
Not applicable. partitio deploys no pools and no factory. It routes through existing Uniswap v3 pools, Uniswap v4 pools and maker pairs on Robinhood Chain, committed to the router by an immutable Merkle root of 161 venues.

TOKEN CONTRACT
Not applicable. partitio has no token.

CODE PRODUCED DURING THE BUILDATHON
All of it. The first commit is dated September 24, 2026, and the deployed contracts come from the tag deploy-v2 at https://github.com/seekdaseek/partitio/tree/deploy-v2. The vendored OpenZeppelin and forge-std libraries are third party.

GITHUB REPOSITORY
https://github.com/seekdaseek/partitio

DEMO VIDEO
https://youtu.be/dxhwqTnKBzo

PITCH VIDEO
https://youtu.be/LvRpVh2GbRk

MAINNET TRADES - not a form field, and longer than the 300-character answers. For the video description.
Shown in the demo video: a mainnet round trip from a wallet that holds no ETH. Buy https://robinhoodchain.blockscout.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe Sell https://robinhoodchain.blockscout.com/tx/0x2504a2e36d1ef0663e4750677dae2fd4b9f079d0727995620300b4507e326e2b The first round trip, same wallet, 90 minutes earlier: Buy https://robinhoodchain.blockscout.com/tx/0x5f8d8c0eff1e5504c346511c7ce1d8cbad775f318cfc5e2ac521ed92ef8cdc56 Sell https://robinhoodchain.blockscout.com/tx/0x668e72767a4ff11981c523954641b8b0de43c1c301ee5cea043e8152918196b2

CONTRACTS ON BLOCKSCOUT - not a form field. The form's core addresses field keeps the Sourcify links.
GaslessEntry https://robinhoodchain.blockscout.com/address/0x9645388051ece3a437D5E224B17c156b16840AC7 PartitioRouterV2 https://robinhoodchain.blockscout.com/address/0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA

SPONSOR TECH - tick these three

Robinhood Chain
Both contracts are deployed on Robinhood Chain, chain id 4663, and every trade settles there against Robinhood stock tokens and their Chainlink feeds.

Paxos USDG
USDG is the quote asset. GaslessEntry funds every buy with USDG's EIP-3009 receiveWithAuthorization, so the buyer signs instead of paying gas, and the relayer's fee is always paid in USDG.

OpenZeppelin
GaslessEntry uses OpenZeppelin EIP712, ECDSA, SafeERC20 and ReentrancyGuardTransient. PartitioRouterV2 uses SafeERC20. Both pin OpenZeppelin 5.1.0.
