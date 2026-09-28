// Tests for the refusals in relayer/submit.mjs.
//
// Every case here must end with sent:false and zero transactions. The float is 0.0002 ETH and a
// revert burns gas just as well as a fill does, so "the contract would have rejected it" is not
// good enough — the relayer has to reject it first.
//
// No chain: these are the checks that happen before any RPC call, plus the revert decoder.
// The on-fork matrix (a real IONQ sell, a stale order, a deployed contract) is separate.
//
// Run: node relayer/submit.test.mjs

import { encodeErrorResult } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { handleOrder, explainRevert, refusalSentence, ownerRateOk, fillResult } from "./submit.mjs";
import { ORDER_TYPES, domainFor, normalizeOrder } from "./order.mjs";

let failures = 0;
const check = (name, ok, detail = "") => {
  if (ok) return;
  failures++;
  console.error(`  FAIL  ${name}${detail ? " :: " + detail : ""}`);
};

const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
const ENTRY = "0x000000000000000000000000000000000000beef";
const KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const account = privateKeyToAccount(KEY);

const baseOrder = {
  owner: account.address,
  tokenIn: USDG,
  amountIn: 1_000_000_000n,
  tokenOut: AAPL,
  minOut: 2_900_000_000_000_000_000n,
  maxFeeUsdg: 5_000_000n,
  deadline: 1_790_000_000n,
  salt: "0x" + "22".repeat(32),
  guard: { maxDevBps: 200n, maxFeedAge: 3600n },
};

async function sign(order) {
  const sig = await account.signTypedData({
    domain: domainFor(ENTRY),
    types: ORDER_TYPES,
    primaryType: "Order",
    message: normalizeOrder(order),
  });
  return {
    signature: sig,
    v: Number("0x" + sig.slice(130, 132)),
    r: "0x" + sig.slice(2, 66),
    s: "0x" + sig.slice(66, 130),
    pv: 27, pr: "0x" + "11".repeat(32), ps: "0x" + "22".repeat(32),
    validAfter: 0, validBefore: order.deadline,
  };
}

const submit = (body) => handleOrder(body, { entryAddress: ENTRY });

// ---------------------------------------------------------------- refusals

console.log("refusals that must never produce a transaction");

{
  const order = { ...baseOrder, minOut: 0n };
  const r = await submit({ order, auth: await sign(order), fee: 1_000_000n, slippageBps: 50 });
  check("minOut == 0 is refused", r.code === 400 && r.out.sent === false, JSON.stringify(r.out));
  check("  and says why", /minOut/i.test(r.out.reason || ""), r.out.reason);
}

{
  const r = await submit({ order: baseOrder, auth: await sign(baseOrder), fee: 1_000_000n, slippageBps: 301 });
  check("slippage above 3% is refused", r.code === 400 && r.out.sent === false, JSON.stringify(r.out));
}

{
  const order = { ...baseOrder, guard: { ...baseOrder.guard, maxFeedAge: 0n } };
  const r = await submit({ order, auth: await sign(order), fee: 1_000_000n, slippageBps: 50 });
  check("maxFeedAge == 0 is refused", r.code === 400 && r.out.sent === false, JSON.stringify(r.out));
}

{
  // signed by the right key, but the order claims a different owner
  const order = { ...baseOrder, salt: "0x" + "33".repeat(32) };
  const auth = await sign(order);
  const tampered = { ...order, owner: "0x000000000000000000000000000000000000dead" };
  const r = await submit({ order: tampered, auth, fee: 1_000_000n, slippageBps: 50 });
  check("a signature that does not match owner is refused",
    r.code === 400 && r.out.sent === false && /owner/i.test(r.out.error || ""), JSON.stringify(r.out));
}

{
  // the signature is over a DIFFERENT order than the one submitted
  const order = { ...baseOrder, salt: "0x" + "44".repeat(32) };
  const auth = await sign(order);
  const swapped = { ...order, amountIn: 2_000_000_000n };
  const r = await submit({ order: swapped, auth, fee: 1_000_000n, slippageBps: 50 });
  check("a signature over different order fields is refused", r.code === 400 && r.out.sent === false);
}

{
  const order = { ...baseOrder, salt: "0x" + "55".repeat(32) };
  const r = await submit({ order, auth: await sign(order), fee: order.amountIn, slippageBps: 50 });
  check("a fee that leaves nothing to route is refused", r.code === 400 && r.out.sent === false, JSON.stringify(r.out));
}

{
  const order = { ...baseOrder, salt: "0x" + "66".repeat(32) };
  const r = await submit({ order, auth: await sign(order), fee: 1_000_000n, slippageBps: 50, ticker: "GLD", direction: "sell" });
  check("a HIDDEN ticker is refused", r.code === 400 && /not offered/i.test(r.out.error || ""), JSON.stringify(r.out));
}

{
  const order = { ...baseOrder, salt: "0x" + "77".repeat(32) };
  const r = await handleOrder({ order, auth: await sign(order), fee: 1_000_000n, slippageBps: 50 }, { entryAddress: null });
  check("no deployed contract means refuse, not crash", r.code === 503 && /not-deployed/.test(r.out.reason || ""));
}

{
  // no legs and no ticker means nothing to route
  const order = { ...baseOrder, salt: "0x" + "88".repeat(32) };
  const r = await submit({ order, auth: await sign(order), fee: 1_000_000n, slippageBps: 50 });
  check("no route is refused before encoding", r.code === 400 && /no route|no venue/i.test(
    (r.out.error || "") + (r.out.reason || "")), JSON.stringify(r.out));
}

console.log("per-owner rate limit");
{
  const who = "0xabc";
  let allowed = 0;
  for (let i = 0; i < 10; i++) if (ownerRateOk(who, 6)) allowed++;
  check("the per-owner limit binds", allowed === 6, `allowed ${allowed}`);
  check("a different owner is unaffected", ownerRateOk("0xdef", 6) === true);
}

// ---------------------------------------------------------------- revert decoding

console.log("revert decoding and the sentences a user sees");

const BELOW = encodeErrorResult({
  abi: [{ type: "error", name: "BelowOracleFloor", inputs: [
    { name: "got", type: "uint256" }, { name: "floorOut", type: "uint256" }, { name: "updatedAt", type: "uint256" }] }],
  errorName: "BelowOracleFloor",
  args: [1n, 2n, 3n],
});
check("BelowOracleFloor decodes by name", explainRevert(BELOW).name === "BelowOracleFloor", explainRevert(BELOW).name);

const STALE = encodeErrorResult({
  abi: [{ type: "error", name: "FeedOlderThanSignerAllows", inputs: [
    { name: "age", type: "uint256" }, { name: "maxFeedAge", type: "uint256" }] }],
  errorName: "FeedOlderThanSignerAllows",
  args: [7200n, 3600n],
});
check("FeedOlderThanSignerAllows decodes", explainRevert(STALE).name === "FeedOlderThanSignerAllows");

const ERRSTR = encodeErrorResult({
  abi: [{ type: "error", name: "Error", inputs: [{ type: "string" }] }],
  errorName: "Error",
  args: ["dust"],
});
check("Error(string) decodes to its message", explainRevert(ERRSTR).detail === "dust", explainRevert(ERRSTR).detail);
check("panic decodes", explainRevert("0x4e487b71" + "11".padStart(64, "0")).name === "Panic");
check("empty revert data does not throw", explainRevert("0x").name === "revert");
check("garbage revert data does not throw", explainRevert("0xdeadbeef").name === "unknown");

// THE IONQ SENTENCE: the quote and the refusal must say the same thing in words a trader can act on
const ionq = refusalSentence({ name: "BelowOracleFloor", detail: "" }, { direction: "sell", oracleDevBps: -1172 });
check("an IONQ-shaped sell refusal names the gap", /11\.7% below Chainlink/.test(ionq), ionq);
console.log("    " + ionq);

// A floor breach with got == 0 means we sized the aggregator's calldata badly, not that the price
// moved. Saying "the price moved" there is a lie that costs a support cycle.
const dust = refusalSentence({ name: "BelowOracleFloor", detail: "0, 2884026238, 1790279713" }, { direction: "buy" });
check("a zero-output floor breach is named as our bug", /relayer bug/.test(dust), dust);
const realPrice = refusalSentence({ name: "BelowOracleFloor", detail: "8752400000, 8900000000, 1790279713" }, { direction: "sell", oracleDevBps: -1172 });
check("a real price breach still reads as a price breach", /below Chainlink/.test(realPrice), realPrice);
console.log("    " + dust);

const staleSentence = refusalSentence({ name: "FeedOlderThanSignerAllows", detail: "" }, {});
check("a stale-reference refusal tells the user to re-sign", /re-quote/i.test(staleSentence), staleSentence);
console.log("    " + staleSentence);

// THE TWO SHORTFALLS SERGIU HIT ON MAINNET, 2026-09-28. A buy of 1 USDG from a wallet holding
// 0.996536 reverted inside USDG with these exact four bytes and the page said "unknown"; a second
// sell of already-sold AAPL reverted with ERC20InsufficientBalance.
const usdgShort = explainRevert("0x356680b7");
check("USDG's InsufficientFunds() decodes by name", usdgShort.name === "InsufficientFunds", JSON.stringify(usdgShort));
const usdgSentence = refusalSentence(usdgShort, { direction: "buy", ticker: "AAPL" });
check("a USDG shortfall reads as one", /not enough USDG/.test(usdgSentence), usdgSentence);
console.log("    " + usdgSentence);

const STOCKSHORT = encodeErrorResult({
  abi: [{ type: "error", name: "ERC20InsufficientBalance", inputs: [
    { name: "sender", type: "address" }, { name: "balance", type: "uint256" }, { name: "needed", type: "uint256" }] }],
  errorName: "ERC20InsufficientBalance",
  args: ["0x0032fB2549Eeb8f6E41106c595d5B1b99bBB7554", 0n, 2905609090167306n],
});
const stockShort = explainRevert(STOCKSHORT);
const stockSentence = refusalSentence(stockShort, { direction: "sell", ticker: "AAPL" });
check("a stock shortfall names the ticker and both amounts",
  /not enough AAPL/.test(stockSentence) && /holds 0,/.test(stockSentence) && /0\.002905609090167306/.test(stockSentence), stockSentence);
console.log("    " + stockSentence);

// THE FILL RESULT: the demo-video buy's receipt, reduced to its Transfer logs (block 74906068).
// Owner deltas only; the entry's and the relayer's own transfers must not leak into them.
{
  const T = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  const top = (a) => "0x" + a.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  const log = (token, from, to, v) => ({ address: token, topics: [T, top(from), top(to)], data: "0x" + v.toString(16).padStart(64, "0") });
  const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
  const OWNER = "0x0032fB2549Eeb8f6E41106c595d5B1b99bBB7554", ENTRY = "0x9645388051ece3a437D5E224B17c156b16840AC7";
  const RELAYER = "0x8155Fe3D74e5D97DC3E6dE119c497A24Aca62216", POOL = "0x2F00000000000000000000000000000000004A07";
  const buy = { blockNumber: "0x476f9d4", logs: [
    log(USDG, OWNER, ENTRY, 990000n), log(USDG, ENTRY, POOL, 985050n), log(AAPL, POOL, ENTRY, 2884009347528764n),
    log(AAPL, ENTRY, OWNER, 2884009347528764n), log(USDG, ENTRY, RELAYER, 4950n),
    { address: USDG, topics: ["0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925", top(OWNER), top(ENTRY)], data: "0x" + "0".repeat(64) } ] };
  const f = fillResult(buy, OWNER, USDG, AAPL);
  check("a buy's fill result is the owner's exact deltas", f.block === "74906068" && f.usdg === "-990000" && f.stock === "2884009347528764", JSON.stringify(f));
  const sell = { blockNumber: "0x476fad2", logs: [
    log(AAPL, OWNER, ENTRY, 2884009347528764n), log(USDG, ENTRY, RELAYER, 4896n), log(USDG, ENTRY, OWNER, 979276n) ] };
  const g = fillResult(sell, OWNER.toLowerCase(), USDG, AAPL);
  check("a sell's fill result is the owner's exact deltas", g.block === "74906322" && g.usdg === "979276" && g.stock === "-2884009347528764", JSON.stringify(g));
  const other = fillResult(buy, RELAYER, USDG, AAPL);
  check("another address's deltas come from its own transfers only", other.usdg === "4950" && other.stock === "0", JSON.stringify(other));
}

// ---------------------------------------------------------------- result

console.log(`\n${failures} failures`);
if (failures > 0) { console.error("FAILED"); process.exit(1); }
console.log("OK");
