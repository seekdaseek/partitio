// Quote a trade every way we can, and say plainly which one wins.
//
// The measured position: partitio runs 1-87 bps BEHIND Kyber when Kyber answers, and Kyber answers
// roughly 47% of the time at our request rate. So the honest product is "the best available price,
// every time" — take the aggregator's number when it is there, and route on-chain when it is not.
// This module returns every source's number so the caller can show the comparison rather than
// assert a winner.
import fs from "node:fs";
import path from "node:path";
import { batch, call } from "./rpc.mjs";
import { USDG, QUOTER_V2, V4_QUOTER } from "./config.mjs";
import { scaleLegsToSpendable } from "./order.mjs";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const REG = JSON.parse(fs.readFileSync(path.join(HERE, "registry.json"), "utf8"));
const TOK = JSON.parse(fs.readFileSync(path.join(HERE, "tokens.json"), "utf8"));
const MAKERS = JSON.parse(fs.readFileSync(path.join(HERE, "makers.json"), "utf8"));
const FEEDS = JSON.parse(fs.readFileSync(path.join(HERE, "chainlink-feeds.json"), "utf8")).feeds;

// Hidden in v1: priced by a Uniswap-pool-derived feed, which cannot guard a trade that moves that
// same pool. See docs/ORACLE-GUARD.md.
export const HIDDEN = new Set(["GLD", "RDDT"]);

const SEL_V3 = "0xc6a5026a";
const SEL_V4 = "0xaa9d21cb";
const SEL_MAKER = "0x8290d9b8";
const SEL_LRD = "0xfeaf968c";
const K = 8;
const MAX_VENUES = 6;

const pad = (h) => String(h).replace(/^0x/, "").toLowerCase().padStart(64, "0");
const padInt = (n) => pad(BigInt(n).toString(16));
const padInt24 = (n) => { const b = BigInt(n); return pad((b < 0n ? (1n << 256n) + b : b).toString(16)); };
const w = (v, i) => v.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);
const lower = (a) => String(a).toLowerCase();

export function tickers() {
  return Object.keys(TOK.tokens).filter((t) => !HIDDEN.has(t) && FEEDS[t]);
}

function venuesFor(ticker) {
  const v3 = REG.v3.filter((v) => v.ticker === ticker && v.quote === "USDG");
  const v4 = REG.v4.filter((v) => v.ticker === ticker && v.quote === "USDG");
  const amm = [...v3, ...v4].sort((a, b) => (BigInt(b.liquidity) > BigInt(a.liquidity) ? 1 : -1)).slice(0, MAX_VENUES);
  const mk = (MAKERS[ticker] || []).map((m) => ({ kind: "maker", family: "fermi-prop", ...m }));
  return [...amm, ...mk];
}

function quoteCall(v, tokenIn, tokenOut, amountIn) {
  if (v.kind === "v3") {
    return { method: "eth_call", params: [{ to: QUOTER_V2,
      data: SEL_V3 + pad(tokenIn) + pad(tokenOut) + padInt(amountIn) + padInt(v.fee) + pad("0") }, "latest"] };
  }
  if (v.kind === "v4") {
    const zeroForOne = lower(v.currency0) === lower(tokenIn);
    const struct = pad(v.currency0) + pad(v.currency1) + padInt(v.fee) + padInt24(v.tickSpacing)
      + pad(v.hooks) + pad(zeroForOne ? "1" : "0") + padInt(amountIn) + padInt(0x100) + padInt(0);
    return { method: "eth_call", params: [{ to: V4_QUOTER, data: SEL_V4 + padInt(0x20) + struct }, "latest"] };
  }
  const zeroForOne = lower(v.token0) === lower(tokenIn);
  return { method: "eth_call", params: [{ to: v.addr,
    data: SEL_MAKER + pad(zeroForOne ? "1" : "0") + padInt(amountIn) }, "latest"] };
}

/// Greedy marginal allocation — identical algorithm to src/lib/GreedySplit.sol, so the relayer's
/// preview and the contract's execution cannot disagree about what a split means.
function greedy(ladders, amountIn) {
  const chunk = amountIn / BigInt(K);
  const alloc = ladders.map(() => 0);
  const f = (vi, n) => (n === 0 ? 0n : ladders[vi].points[n - 1]);
  for (let c = 0; c < K; c++) {
    let bi = -1, best = 0n;
    for (let vi = 0; vi < ladders.length; vi++) {
      const cur = f(vi, alloc[vi]), nxt = f(vi, alloc[vi] + 1);
      if (nxt === null || cur === null) continue;
      const g = nxt - cur;
      if (g > best) { best = g; bi = vi; }
    }
    if (bi < 0) break;
    alloc[bi]++;
  }
  const legs = [];
  let total = 0n;
  for (let vi = 0; vi < ladders.length; vi++) {
    if (!alloc[vi]) continue;
    legs.push({ venue: ladders[vi].id, family: ladders[vi].family, kind: ladders[vi].kind,
                amountIn: (chunk * BigInt(alloc[vi])).toString(), amountOut: f(vi, alloc[vi]).toString() });
    total += f(vi, alloc[vi]);
  }
  return { total, legs, chunk };
}

/// @param amountIn MUST be the SPENDABLE amount — what GaslessEntry actually routes once the fee
/// is taken off, i.e. `spendableFor()` from ./order.mjs. Quoting the gross and routing the net is
/// how the legs used to come up short: the contract now rejects any route whose legs do not sum to
/// exactly the spendable amount, so a quote against the gross is a guaranteed revert.
/// @returns on-chain numbers: the best single venue, the greedy split, and the Chainlink reference.
export async function onChainQuote(ticker, direction, amountIn) {
  const token = TOK.tokens[ticker];
  if (!token) throw new Error(`unknown ticker ${ticker}`);
  if (HIDDEN.has(ticker)) throw new Error(`${ticker} is not offered in v1 (pool-derived oracle)`);
  const tokenIn = direction === "sell" ? token : USDG;
  const tokenOut = direction === "sell" ? USDG : token;

  const venues = venuesFor(ticker);
  const chunk = amountIn / BigInt(K);
  const jobs = [];
  for (const v of venues) for (let n = 1; n <= K; n++) jobs.push({ v, n, amt: chunk * BigInt(n) });

  const res = await batch(jobs.map((j) => quoteCall(j.v, tokenIn, tokenOut, j.amt)));
  const ladders = venues.map((v) => ({
    id: v.kind === "v4" ? v.poolId : v.addr,
    family: v.family || (v.kind === "v4" ? "uniswap-v4" : "uniswapv3"),
    kind: v.kind, points: new Array(K).fill(null),
  }));
  jobs.forEach((j, i) => {
    const r = res[i];
    if (!r || r === "0x") return;
    let out;
    try { out = BigInt("0x" + w(r, 0)); } catch { return; }
    if (out > 0n) ladders[venues.indexOf(j.v)].points[j.n - 1] = out;
  });

  const unmeasured = ladders.reduce((a, L) => a + L.points.filter((p) => p === null).length, 0);
  let bestSingle = null, bestId = null, bestFamily = null;
  for (const L of ladders) {
    const full = L.points[K - 1];
    if (full === null) continue;
    if (bestSingle === null || full > bestSingle) { bestSingle = full; bestId = L.id; bestFamily = L.family; }
  }
  let split = greedy(ladders, amountIn);

  // INVARIANT: partitio is never worse than the best single venue. Greedy stops early when the
  // upper ladder rungs are unmeasured, which leaves part of the order unrouted and makes the
  // split look thin. If that happens, route the whole order to the best single venue instead —
  // a partial split is a measurement failure, not a price.
  if (bestSingle !== null && split.total < bestSingle) {
    const L = ladders.find((x) => x.id === bestId);
    split = { total: bestSingle, chunk,
      legs: [{ venue: bestId, family: bestFamily, kind: L?.kind ?? "v3",
               amountIn: amountIn.toString(), amountOut: bestSingle.toString() }] };
  }

  // The legs must sum to EXACTLY `amountIn` (the spendable amount) or GaslessEntry reverts
  // LegsDoNotCoverOrder. Greedy allocates in chunks of amountIn/K, so its legs sum to
  // amountIn - (amountIn mod K) — up to K-1 wei short, which is a revert, not a rounding
  // nicety. Verified: amountIn = 12_345_678 with K = 8 produced legs summing to 12_345_672.
  if (split.legs.length > 0) {
    split.legs = scaleLegsToSpendable(split.legs, amountIn);
  } else if (bestSingle !== null) {
    // every rung unmeasured but one venue answered at full size
    const L = ladders.find((x) => x.id === bestId);
    split = { total: bestSingle, chunk,
      legs: [{ venue: bestId, family: bestFamily, kind: L?.kind ?? "v3",
               amountIn: amountIn.toString(), amountOut: bestSingle.toString() }] };
  }

  // Chainlink reference and the expected deviation at this size — shown in the preview so the
  // user's band can cover real impact instead of the guard rejecting it.
  const feed = FEEDS[ticker];
  let oracleOut = null, oracleDevBps = null, updatedAt = null;
  if (feed) {
    const lrd = await call("eth_call", [{ to: feed.feed, data: SEL_LRD }, "latest"]).catch(() => null);
    if (lrd && lrd !== "0x") {
      const answer = BigInt("0x" + w(lrd, 1));
      updatedAt = Number(BigInt("0x" + w(lrd, 3)));
      const dec = BigInt(10) ** BigInt(feed.decimals ?? 8);
      oracleOut = direction === "sell"
        ? (amountIn * answer * 1000000n) / (10n ** 18n * dec)
        : (amountIn * 10n ** 18n * dec) / (1000000n * answer);
      if (oracleOut > 0n && split.total > 0n) {
        oracleDevBps = Number(((split.total - oracleOut) * 10000n) / oracleOut);
      }
    }
  }

  const legSum = split.legs.reduce((a, l) => a + BigInt(l.amountIn), 0n);

  return {
    ticker, direction, amountIn: amountIn.toString(), legSum: legSum.toString(),
    legsCoverOrder: legSum === amountIn,
    bestSingle: bestSingle?.toString() ?? null, bestSingleVenue: bestId, bestSingleFamily: bestFamily,
    partitio: split.total.toString(), legs: split.legs, venuesUsed: split.legs.length,
    unmeasuredRungs: unmeasured, totalRungs: ladders.length * K,
    oracleOut: oracleOut?.toString() ?? null, oracleDevBps, oracleUpdatedAt: updatedAt,
    oracleFeed: feed?.feed ?? null, oracleDesc: feed?.desc ?? null,
  };
}
