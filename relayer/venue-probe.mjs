// Does every committed venue of a ticker actually SETTLE through the deployed router?
//
// Simulates a fill routed 100% through each venue in turn, on a local anvil fork, against the
// contracts already on mainnet. A committed venue that quotes but cannot settle is the worst kind:
// the quote engine picks it, simulation refuses the fill, and the user sees a refusal for a price
// that looked fine. Anvil only - it impersonates accounts.
//
// Run: PARTITIO_RPC_OVERRIDE=http://127.0.0.1:8545 node relayer/venue-probe.mjs AAPL
import { legVenue, committed } from "./venues.mjs";
import { simulate, explainRevert } from "./submit.mjs";
import { call } from "./rpc.mjs";
import { encodeFunctionData, parseAbi } from "viem";
import fs from "node:fs";
import { assertLocalAnvil } from "./sender.mjs";
await assertLocalAnvil(process.env.PARTITIO_RPC_OVERRIDE || "http://unset");
const TICKER = process.argv[2] || "AAPL";
const ROUTER = "0x22be28fd3AECa3A1ba4a918E4DD458ba6B5E09EA";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const TOKENS = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url), "utf8")).tokens;
const RABI = JSON.parse(fs.readFileSync(new URL("../out/PartitioRouterV2.sol/PartitioRouterV2.json", import.meta.url),"utf8")).abi;
const ERC = parseAbi(["function approve(address,uint256) returns (bool)","function transfer(address,uint256) returns (bool)","function balanceOf(address) view returns (uint256)"]);
await call("evm_mine", []);
const WHO = "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"; // anvil #5, impersonated
const FUNDER = "0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed";
for (const a of [WHO, FUNDER]) { await call("anvil_impersonateAccount", [a]); await call("anvil_setBalance", [a, "0xde0b6b3a7640000"]); }
const send = async (from, to, data) => { const h = await call("eth_sendTransaction", [{ from, to, data }]); return call("eth_getTransactionReceipt", [h]); };
await send(FUNDER, USDG, encodeFunctionData({ abi: ERC, functionName: "transfer", args: [WHO, 10_000_000n] }));
await send(WHO, USDG, encodeFunctionData({ abi: ERC, functionName: "approve", args: [ROUTER, 10n**30n] }));
const STOCK = TOKENS[TICKER];
await send(FUNDER, STOCK, encodeFunctionData({ abi: ERC, functionName: "transfer", args: [WHO, 10n ** 16n] }));
await send(WHO, STOCK, encodeFunctionData({ abi: ERC, functionName: "approve", args: [ROUTER, 10n ** 30n] }));
const makers = committed().venues.filter((v) => v.ticker === TICKER);
console.log(`buy 1 USDG of ${TICKER}, one venue at a time:`);
for (const v of makers) {
  const lv = legVenue(v.id);
  const amt = 1_000_000n;
  const data = encodeFunctionData({ abi: RABI, functionName: "swapExactIn", args: [USDG, TOKENS[TICKER],
    [{ venue: lv.venueStruct, proof: lv.proof, amountIn: amt }], { maxDevBps: 200n, maxFeedAge: 432000n }, 1n, WHO, 99999999999n] });
  const sim = await simulate({ to: ROUTER, from: WHO, data });
  const out = sim.ok ? BigInt(sim.result) : null;
  console.log(`${v.kind.padEnd(5)} ${v.id.slice(0, 12)}  ${sim.ok ? "SETTLES  out " + out : "REVERTS  " + JSON.stringify(explainRevert(sim.data))}`);
}
console.log(`\nsell 0.003 ${TICKER} for USDG, one venue at a time:`);
for (const v of makers) {
  const lv = legVenue(v.id);
  const amt = 3_000_000_000_000_000n;
  const data = encodeFunctionData({ abi: RABI, functionName: "swapExactIn", args: [STOCK, USDG,
    [{ venue: lv.venueStruct, proof: lv.proof, amountIn: amt }], { maxDevBps: 200n, maxFeedAge: 432000n }, 1n, WHO, 99999999999n] });
  const sim = await simulate({ to: ROUTER, from: WHO, data });
  console.log(`${v.kind.padEnd(5)} ${v.id.slice(0, 12)}  ${sim.ok ? "SETTLES  out " + BigInt(sim.result) : "REVERTS  " + JSON.stringify(explainRevert(sim.data))}`);
}
