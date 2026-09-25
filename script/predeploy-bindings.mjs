// Pre-deploy check 4a: every token -> feed binding, verified on-chain.
//
// The router's feed map is IMMUTABLE. A wrong binding is not a bug you patch, it is a redeploy —
// and the deployer holds roughly one redeploy's worth of ETH. So this runs before the deploy
// batch, not after it.
//
// It checks, for every ticker that has both a token and a feed:
//   token.symbol() matches the ticker
//   token.decimals()
//   feed.description() carries the ticker
//   feed.decimals()
//   feed.latestRoundData() answers, and the price is within 2% of the deepest pool mid
//
// Run: node script/predeploy-bindings.mjs
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const RPC = process.env.PARTITIO_RPC || "https://rpc.mainnet.chain.robinhood.com";
const USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168";
// Priced by a Uniswap-pool-derived feed rather than Chainlink, so the guard cannot use them: a
// pool price cannot guard a trade that moves that same pool. Confirmed on-chain - both report
// description() "Uniswap V3 Pool Price in USD" with 18 decimals, and both are the only feeds
// observed reporting updatedAt AHEAD of the chain clock, which is what a non-Chainlink source
// looks like from here.
const HIDDEN = new Set(["GLD", "RDDT"]);
const PRICE_TOLERANCE_PCT = 2;

// Resolve `cast` explicitly. A check that silently returns null when its own tool is missing
// reports every binding as broken, which is indistinguishable from 37 genuinely bad feeds and is
// far worse than no check at all — it happened on the first run of this script.
const CAST = (() => {
  for (const c of [process.env.CAST_BIN, "cast", `${process.env.HOME}/.foundry/bin/cast`]) {
    if (!c) continue;
    try { execFileSync(c, ["--version"], { encoding: "utf8" }); return c; } catch {}
  }
  console.error("FATAL: cannot run `cast`. Install Foundry or set CAST_BIN. Refusing to report.");
  process.exit(2);
})();

let rpcFailures = 0;
const cast = (args) => {
  try { return execFileSync(CAST, [...args, "--rpc-url", RPC], { encoding: "utf8" }).trim(); }
  catch { rpcFailures++; return null; }
};

const tokens = JSON.parse(fs.readFileSync("evidence/tokens.json", "utf8")).tokens;
const feeds = JSON.parse(fs.readFileSync("script/recon/chainlink-feeds.json", "utf8")).feeds;
const venues = JSON.parse(fs.readFileSync("script/recon/venues.json", "utf8")).venues;

const syms = Object.keys(tokens).filter((s) => feeds[s]).sort();
let problems = [];
const bind = [];

console.log("sym     symbol()  tdec  feed description()              fdec        price     pool mid     diff");
console.log("-".repeat(104));

for (const s of syms) {
  const t = tokens[s], f = feeds[s].feed;
  const symbol = (cast(["call", t, "symbol()(string)"]) || "").replace(/"/g, "");
  const tdec = (cast(["call", t, "decimals()(uint8)"]) || "?").split(/\s/)[0];
  const desc = (cast(["call", f, "description()(string)"]) || "").replace(/"/g, "");
  const fdec = (cast(["call", f, "decimals()(uint8)"]) || "?").split(/\s/)[0];
  const lrd = cast(["call", f, "latestRoundData()(uint80,int256,uint256,uint256,uint80)"]);
  const price = lrd ? Number(lrd.split("\n")[1].split(/\s/)[0]) / 10 ** Number(fdec) : NaN;

  // HIDDEN tickers are not bound, so their feeds are not a deploy decision - they are the
  // reason those tickers are excluded in the first place.
  const gate = (msg) => { if (!HIDDEN.has(s)) problems.push(`${s}: ${msg}`); };
  if (symbol !== s) gate(`token symbol() is "${symbol}"`);
  if (!desc.toUpperCase().replace("RH", "").includes(s.toUpperCase()))
    gate(`feed description "${desc}" does not carry the ticker`);
  if (!Number.isFinite(price) || price <= 0) gate("feed has no usable price");

  // deepest ACTIVE v3 pool quoted against USDG, for a price sanity cross-check. Absence is not a
  // fault: several tickers trade only on v4, which this check does not read.
  let mid = NaN;
  const cands = (venues[s] || []).filter((v) => v.kind === "v3" && v.active && v.quote === "USDG");
  if (cands.length) {
    const pool = cands.reduce((a, b) => (BigInt(b.liquidity) > BigInt(a.liquidity) ? b : a));
    const slot = cast(["call", pool.addr, "slot0()"]);
    const t0 = (cast(["call", pool.addr, "token0()(address)"]) || "").split(/\s/)[0].toLowerCase();
    if (slot && t0) {
      const sq = BigInt("0x" + slot.slice(2, 66));
      const praw = Number(sq * sq) / 2 ** 192;
      mid = t0 === USDG ? 1e12 / praw : praw * 1e12;
    }
  }
  const diff = Number.isFinite(mid) ? ((mid - price) / price) * 100 : NaN;
  if (Number.isFinite(diff) && Math.abs(diff) > PRICE_TOLERANCE_PCT)
    gate(`feed is ${diff.toFixed(2)}% from the deepest v3 pool mid`);

  const tag = HIDDEN.has(s) ? "HIDDEN" : "bind";
  if (!HIDDEN.has(s)) bind.push([s, t, f]);
  console.log(
    `${s.padEnd(7)} ${symbol.padEnd(9)} ${tdec.padEnd(5)} ${desc.slice(0, 30).padEnd(31)} ${fdec.padEnd(5)}` +
    ` ${price.toFixed(4).padStart(11)} ${(Number.isFinite(mid) ? mid.toFixed(4) : "-").padStart(12)}` +
    ` ${(Number.isFinite(diff) ? diff.toFixed(2) + "%" : "-").padStart(8)}  ${tag}`
  );
}

console.log(`\ntickers with a token and a feed: ${syms.length}`);
console.log(`excluded as HIDDEN (pool-derived oracle): ${[...HIDDEN].join(", ")}`);
console.log(`WOULD BE BOUND AT DEPLOY: ${bind.length}`);
console.log(`\nconstructor args:`);
console.log(`  stockTokens = [${bind.map((b) => b[1]).join(",")}]`);
console.log(`  feeds       = [${bind.map((b) => b[2]).join(",")}]`);

// A run where most calls failed is an RPC problem, not a binding problem, and must not read as
// one. Two calls per ticker are load-bearing; anything above a tenth failing is the endpoint.
if (rpcFailures > syms.length * 0.2) {
  console.error(`\nFATAL: ${rpcFailures} RPC calls failed. This is the endpoint, not the bindings.`);
  process.exit(2);
}

if (problems.length) {
  console.log(`\n${problems.length} PROBLEM(S) — do not deploy without a decision on each:`);
  for (const p of problems) console.log("  - " + p);
  process.exit(1);
}
console.log("\nall bindings verified");
