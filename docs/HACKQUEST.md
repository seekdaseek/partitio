HACKQUEST SUBMISSION - partitio

Paste each answer exactly as written. Every answer is plain sentences, under 300 characters,
with no markdown, no em dashes and no parentheses. The project does not exist on HackQuest yet:
create it first, then fill the fields below.

========================================================================
PROJECT PAGE
========================================================================

PROJECT NAME
partitio

ONE-LINER
Tokenized stocks on Robinhood Chain at the best single pool's price or better, floored against Chainlink, and no ETH needed to trade.

DESCRIPTION
partitio quotes every committed pool for a stock and splits the order only when that beats the best single pool. The contract checks every fill against Chainlink and reverts outside the band. Users sign twice and hold no ETH, because a relayer pays the gas.

HEADLINE
A $100,000 stock-token order on Robinhood Chain sent to the best single pool left a median $199 on the table in 6,329 of 7,493 executable quotes. partitio splits it and floors the fill against Chainlink.

HEADLINE CAVEAT
Quoted, not executed. The beta caps trades at $50. Runs 1 to 245, September 24 to 27, 2026. The query is evidence/headline.mjs and it recomputes offline with evidence/headline-offline.mjs.

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
PENDING. Recorded Monday, September 28, during US market hours. Paste the video link here before submitting.

SPONSOR TECH - tick these three

Robinhood Chain
Both contracts are deployed on Robinhood Chain, chain id 4663, and every trade settles there against Robinhood stock tokens and their Chainlink feeds.

Paxos USDG
USDG is the quote asset. GaslessEntry funds every buy with USDG's EIP-3009 receiveWithAuthorization, so the buyer signs instead of paying gas, and the relayer's fee is always paid in USDG.

OpenZeppelin
GaslessEntry uses OpenZeppelin EIP712, ECDSA, SafeERC20 and ReentrancyGuardTransient. PartitioRouterV2 uses SafeERC20. Both pin OpenZeppelin 5.1.0.
