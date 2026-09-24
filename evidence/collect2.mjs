// partitio evidence engine v2.
//
// v2 changes:
//   - BOTH DIRECTIONS. Buying (USDG -> stock) is now the product's main path, so it is measured
//     alongside selling instead of inferred from it. A venue can be deep one way and thin the other.
//   - Every Kyber response is logged in full: http status, api code, message, hop count, family
//     list and the off-chain RFQ share of the route.
//   - Rialto maker pairs are quoted in both directions too; a maker that fills a buy may decline
//     the sell at the same size, and refusal stays distinct from failure.
//
// Every 10 minutes: for each of 18 tickers x {1k,10k,100k,500k} USD sold into USDG, record
// per-venue on-chain quotes, the best single venue, the best single protocol, a greedy split
// computed from those same quotes, and the two Kyber yardsticks.
//
// Rules this file exists to obey:
//   - A failed call is `unmeasured` with amount_out NULL. Never an imputed zero.
//   - A maker returning 0 is `refused` — a different fact, kept distinguishable.
//   - The split is labelled `split_sim` until the router is deployed, then `split_router`
//     from an eth_call against the contract. The label never lies about its source.
import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { DatabaseSync } from "node:sqlite";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const RPC = process.env.PARTITIO_RPC || "https://rpc.mainnet.chain.robinhood.com";
const DB_PATH = process.env.PARTITIO_DB || path.join(HERE, "partitio-v2.db");
const PORT = Number(process.env.PARTITIO_PORT || 3030);
const INTERVAL_MS = Number(process.env.PARTITIO_INTERVAL_MS || 10 * 60 * 1000);
const KYBER = "https://aggregator-api.kyberswap.com/robinhood/api/v1/routes";
const KYBER_CLIENT = "partitio-evidence";
const LIFI_MIN_GAP_MS = 60 * 60 * 1000;   // LI.FI at most hourly, per instruction

const SIZES_USD = [1000, 10000, 100000, 500000];
const K_CHUNKS = 8;               // ladder points per venue; greedy allocates K chunks
const MAX_AMM_VENUES = 6;         // top by liquidity, to bound calls per run
const BATCH = 40;
const BATCH_PACE_MS = 250;
const KYBER_PACE_MS = 4000;       // Kyber rate-limits hard; this is deliberately slow
const KYBER_ROTATE = 3;           // each run samples 1/KYBER_ROTATE of the grid (see note below)

// MEASUREMENT HAZARD, observed 2026-09-24: Kyber returns DEGRADED routes under load. The same
// AAPL $500k order returned 497,516.842698 on one call and 426,385.109388 on another minutes
// later - a 15% spread, with the low reading collapsing onto a single venue. A degraded
// baseline makes partitio look better than it is, which is the most dangerous direction for an
// error to run. Two defences: every response records its hop count and family list, and
// headline comparisons take the BEST Kyber observation across runs for a (ticker,size), never a
// single sample. Every uncertainty is biased AGAINST partitio.

const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const QUOTER_V2 = "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7";
const V4_QUOTER = "0x8dc178efb8111bb0973dd9d722ebeff267c98f94";
const ZERO = "0x0000000000000000000000000000000000000000";

// selectors (computed with `cast sig`, asserted in evidence/SELECTORS.md)
const SEL_QUOTE_V3 = "0xc6a5026a";   // quoteExactInputSingle((address,address,uint256,uint24,uint160))
const SEL_QUOTE_V4 = "0xaa9d21cb";   // quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))
const SEL_GET_AMOUNT_OUT = "0x8290d9b8"; // getAmountOut(bool,uint256)

// Kyber families that are proven contracts -> the "on-chain only" yardstick.
// pmm-19 and kipseli-prop are synthetic ids (off-chain RFQ) and are deliberately excluded.
const ONCHAIN_FAMILIES = ["uniswapv3", "uniswap-v4", "uniswap-v4-fables", "uniswap-v4-arrakis", "up-v3", "fermi-prop"];

const REGISTRY = JSON.parse(fs.readFileSync(path.join(HERE, "registry.json"), "utf8"));
const TICKERS = JSON.parse(fs.readFileSync(path.join(HERE, "tickers18.json"), "utf8")).tickers;
const TOKENS = JSON.parse(fs.readFileSync(path.join(HERE, "tokens.json"), "utf8")).tokens;
const MAKERS = JSON.parse(fs.readFileSync(path.join(HERE, "makers.json"), "utf8"));

const pad = (h) => String(h).replace(/^0x/, "").toLowerCase().padStart(64, "0");
const padInt = (n) => pad(BigInt(n).toString(16));
// int24 as a 256-bit two's complement word (tickSpacing is positive in practice, but be correct)
const padInt24 = (n) => { const b = BigInt(n); return pad((b < 0n ? (1n << 256n) + b : b).toString(16)); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const lower = (a) => a.toLowerCase();
const log = (...a) => console.log(new Date().toISOString(), ...a);

let rpcId = 0;
async function rpcBatch(calls, retries = 4) {
  if (!calls.length) return [];
  const body = calls.map((c) => ({ jsonrpc: "2.0", id: ++rpcId, method: "eth_call", params: [{ to: c.to, data: c.data }, "latest"] }));
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1500 * 2 ** (i - 1));
    const r = await fetch(RPC, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body), signal: AbortSignal.timeout(60000),
    }).catch((e) => ({ _err: String(e.message || e) }));
    if (r._err || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!Array.isArray(j)) continue;
    const byId = new Map(j.map((x) => [x.id, x]));
    return body.map((b) => {
      const res = byId.get(b.id);
      if (!res) return { err: "missing from batch" };
      if (res.error) return { err: String(res.error.message || "error").slice(0, 200) };
      return { ok: res.result };
    });
  }
  return calls.map(() => ({ err: "rate-limited after retries" }));
}
async function runBatched(items, make) {
  const out = [];
  for (let i = 0; i < items.length; i += BATCH) {
    out.push(...(await rpcBatch(items.slice(i, i + BATCH).map(make))));
    if (i + BATCH < items.length) await sleep(BATCH_PACE_MS);
  }
  return out;
}
async function rpc(method, params) {
  const r = await fetch(RPC, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }), signal: AbortSignal.timeout(30000),
  });
  const j = await r.json();
  return j.error ? null : j.result;
}

// ---- venue selection: top AMM venues by liquidity, plus every maker for that ticker ----
function venuesFor(ticker) {
  const v3 = REGISTRY.v3.filter((v) => v.ticker === ticker && v.quote === "USDG");
  const v4 = REGISTRY.v4.filter((v) => v.ticker === ticker && v.quote === "USDG");
  const amm = [...v3, ...v4].sort((a, b) => (BigInt(b.liquidity) > BigInt(a.liquidity) ? 1 : -1)).slice(0, MAX_AMM_VENUES);
  const mk = (MAKERS[ticker] || []).map((m) => ({ kind: "maker", family: "fermi-prop", ticker, ...m }));
  return [...amm, ...mk];
}

function quoteCall(v, tokenIn, tokenOut, amountIn) {
  if (v.kind === "v3") {
    return { to: QUOTER_V2, data: SEL_QUOTE_V3 + pad(tokenIn) + pad(tokenOut) + padInt(amountIn) + padInt(v.fee) + pad("0") };
  }
  if (v.kind === "v4") {
    const zeroForOne = lower(v.currency0) === lower(tokenIn);
    // QuoteExactSingleParams{ PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData }
    // The struct contains `bytes`, so it is DYNAMIC: the head is a 0x20 offset to the struct, and
    // hookData's own offset is 8 words (0x100) from the struct start. Verified against a live quote.
    const struct =
      pad(v.currency0) + pad(v.currency1) + padInt(v.fee) + padInt24(v.tickSpacing) + pad(v.hooks) +
      pad(zeroForOne ? "1" : "0") + padInt(amountIn) + padInt(0x100) + padInt(0);
    return { to: V4_QUOTER, data: SEL_QUOTE_V4 + padInt(0x20) + struct };
  }
  const zeroForOne = lower(v.token0) === lower(tokenIn);
  return { to: v.addr, data: SEL_GET_AMOUNT_OUT + pad(zeroForOne ? "1" : "0") + padInt(amountIn) };
}

function decodeQuote(v, res) {
  if (res.err) return { status: "unmeasured", out: null, err: res.err };
  if (!res.ok || res.ok === "0x") return { status: "unmeasured", out: null, err: "empty return" };
  let out;
  try { out = BigInt("0x" + res.ok.replace(/^0x/, "").slice(0, 64)); }
  catch { return { status: "unmeasured", out: null, err: "undecodable" }; }
  if (out === 0n) return { status: "refused", out: 0n, err: null };
  return { status: "ok", out, err: null };
}

// ---- greedy marginal allocation over the ladder ----
function greedySplit(ladders, amountIn, k) {
  const chunk = amountIn / BigInt(k);
  const alloc = ladders.map(() => 0);
  const f = (vi, n) => (n === 0 ? 0n : (ladders[vi].points[n - 1] ?? null));
  for (let c = 0; c < k; c++) {
    let bestVi = -1, bestGain = 0n;
    for (let vi = 0; vi < ladders.length; vi++) {
      const cur = f(vi, alloc[vi]);
      const nxt = f(vi, alloc[vi] + 1);
      if (nxt === null || cur === null) continue;       // venue capped or unmeasured here
      const gain = nxt - cur;
      if (gain > bestGain) { bestGain = gain; bestVi = vi; }
    }
    if (bestVi < 0) break;                               // nothing improves: stop allocating
    alloc[bestVi]++;
  }
  const legs = [];
  let total = 0n, used = 0n;
  for (let vi = 0; vi < ladders.length; vi++) {
    if (!alloc[vi]) continue;
    const amt = chunk * BigInt(alloc[vi]);
    const outv = f(vi, alloc[vi]);
    legs.push({ venue_id: ladders[vi].id, family: ladders[vi].family, kind: ladders[vi].kind, amount_in: amt.toString(), amount_out: outv.toString(), chunks: alloc[vi] });
    total += outv; used += amt;
  }
  return { total, legs, used, chunk };
}

// ---- Kyber ----
// The `includedSources` restriction is NOT trusted. Every response is checked against the
// families that actually came back: if an off-chain source (pmm-19, kipseli-prop, ...) appears
// in a supposedly restricted route, the row is recorded `unmeasured` with the leak named, not
// quietly used as an on-chain baseline. Trusting the parameter is how the brief's void
// "on-chain AMMs only" column came to include kipseli-prop.
const OFFCHAIN_IDS = ["pmm-19", "kipseli-prop"];
async function kyber(tokenIn, tokenOut, amountIn, includedSources) {
  let url = `${KYBER}?tokenIn=${tokenIn}&tokenOut=${tokenOut}&amountIn=${amountIn}`;
  if (includedSources) url += `&includedSources=${encodeURIComponent(includedSources.join(","))}`;
  let lastClass = null;
  for (let i = 0; i < 3; i++) {
    if (i) await sleep(8000 * i);
    try {
      const r = await fetch(url, { headers: { "x-client-id": KYBER_CLIENT }, signal: AbortSignal.timeout(25000) });
      const j = await r.json();
      if (j?.data?.routeSummary) {
        // Kyber's route is route[parallelSplit][sequentialHop]. RFQ share is a share of the INPUT
        // across parallel splits, so it is computed from each split's FIRST hop `swapAmount`.
        // Summing amountOut over every hop double-counts sequential legs and silently dilutes the
        // share toward zero — the first version of this did exactly that and reported 0.0%.
        const fams = new Set();
        let hops = 0, offchainIn = 0n, totalIn = 0n;
        for (const leg of j.data.routeSummary.route || []) {
          for (const h of leg) { fams.add(h.exchange); hops++; }
          const first = leg[0];
          if (!first) continue;
          const amt = BigInt(first.swapAmount || 0);
          totalIn += amt;
          if (OFFCHAIN_IDS.includes(first.exchange)) offchainIn += amt;
        }
        const families = [...fams].sort();
        const rfqShare = totalIn > 0n ? Number((offchainIn * 10000n) / totalIn) / 100 : 0;
        if (includedSources) {
          const leaked = families.filter((f) => !includedSources.includes(f));
          if (leaked.length) {
            return { out: null, status: "unmeasured", families, hops,
                     err: `includedSources ignored; leaked: ${leaked.join(",")}` };
          }
        }
        return { out: BigInt(j.data.routeSummary.amountOut), status: "ok", families, hops, rfqShare, http: r.status };
      }
      // classify rather than lumping every non-answer together
      const code = j?.code, msg = j?.message || "";
      if (code === 50301) { lastClass = { cls: "overloaded", http: r.status, code, msg }; continue; }
      const cls = r.status === 429 ? "rate-limited"
                : /no route|not found/i.test(msg) ? "no-route" : "error";
      return { out: null, status: "unmeasured", cls, http: r.status, code, err: msg || `code ${code}` };
    } catch (e) {
      lastClass = { cls: "transport", http: 0, msg: String(e.message || e) };
      if (i === 2) return { out: null, status: "unmeasured", cls: "transport", err: String(e.message || e) };
    }
  }
  return { out: null, status: "unmeasured", cls: lastClass?.cls || "overloaded",
           http: lastClass?.http, code: lastClass?.code, err: lastClass?.msg || "overloaded after retries" };
}

// ---- db ----
const db = new DatabaseSync(DB_PATH);
db.exec(fs.readFileSync(path.join(HERE, "schema2.sql"), "utf8"));
const insQuote = db.prepare(`INSERT INTO quote (run_id,ticker,direction,size_usd,amount_in,family,kind,venue_id,chunk_ix,amount_out,status,err)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`);
const insKyber = db.prepare(`INSERT INTO kyber_call (run_id,at,ticker,direction,size_usd,restricted,status,cls,http,api_code,hops,families,rfq_share,amount_out,err)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
const insAgg = db.prepare(`INSERT OR REPLACE INTO agg (run_id,ticker,direction,size_usd,amount_in,best_venue_out,best_venue_id,best_venue_family,
  best_v3_out,best_v4_out,best_maker_out,split_out,split_kind,split_legs,split_venue_count,
  kyber_all_out,kyber_all_status,kyber_onchain_out,kyber_onchain_status,lifi_out,lifi_status)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);

let lastLifi = 0;

function recordKyber(runId, ticker, direction, sizeUsd, restricted, k) {
  insKyber.run(runId, new Date().toISOString(), ticker, direction, sizeUsd, restricted,
    k.status ?? "unmeasured", k.cls ?? null, k.http ?? null, k.code ?? null,
    k.hops ?? null, k.families ? k.families.join("|") : null,
    k.rfqShare ?? null, k.out?.toString() ?? null, k.err ?? null);
}

async function runOnce() {
  const startedAt = new Date().toISOString();
  const block = parseInt((await rpc("eth_blockNumber", [])) || "0x0", 16);
  const gasPrice = await rpc("eth_gasPrice", []);
  const runId = db.prepare("INSERT INTO run (started_at,block,gas_price,router_addr,note) VALUES (?,?,?,?,?) RETURNING id")
    .get(startedAt, block, gasPrice ?? null, process.env.PARTITIO_ROUTER || null, `K=${K_CHUNKS} maxAmm=${MAX_AMM_VENUES}`).id;
  db.prepare("INSERT INTO kyber_sources (run_id,included) VALUES (?,?)").run(runId, ONCHAIN_FAMILIES.join(","));
  log(`run ${runId} block ${block}`);

  // unit prices from the deepest v3 venue, 1 token in
  const priced = [];
  const priceRes = await runBatched(TICKERS, (t) => {
    const v = venuesFor(t).find((x) => x.kind === "v3") || venuesFor(t)[0];
    return quoteCall(v, TOKENS[t], USDG, 10n ** 18n);
  });
  TICKERS.forEach((t, i) => {
    const v = venuesFor(t).find((x) => x.kind === "v3") || venuesFor(t)[0];
    const d = decodeQuote(v, priceRes[i]);
    if (d.status === "ok") priced.push({ ticker: t, usd: Number(d.out) / 1e6 });
    else log(`  ${t}: no unit price (${d.status}) - skipped this run`);
  });

  let nQuotes = 0, nUnmeasured = 0;
  for (const { ticker, usd } of priced) {
    const token = TOKENS[ticker];
    const venues = venuesFor(ticker);

    // Both directions. Buying is the product's main path; a venue deep on the sell side can be
    // thin on the buy side, so it is measured rather than assumed symmetric.
    for (const direction of ["sell", "buy"]) {
      const tokenIn = direction === "sell" ? token : USDG;
      const tokenOut = direction === "sell" ? USDG : token;

      for (const sizeUsd of SIZES_USD) {
        // sell: size in stock units at the live price. buy: size straight in USDG (6dp).
        const amountIn = direction === "sell"
          ? BigInt(Math.floor((sizeUsd / usd) * 1e18))
          : BigInt(sizeUsd) * 1000000n;
        const chunk = amountIn / BigInt(K_CHUNKS);
        if (chunk === 0n) continue;

        const jobs = [];
        for (const v of venues) for (let n = 1; n <= K_CHUNKS; n++) jobs.push({ v, n, amt: chunk * BigInt(n) });
        const res = await runBatched(jobs, (j) => quoteCall(j.v, tokenIn, tokenOut, j.amt));

        const ladders = venues.map((v) => ({
          id: v.kind === "v4" ? v.poolId : v.addr,
          family: v.family || (v.kind === "v4" ? "uniswap-v4" : "uniswapv3"),
          kind: v.kind, points: new Array(K_CHUNKS).fill(null),
        }));
        jobs.forEach((j, i) => {
          const vi = venues.indexOf(j.v);
          const d = decodeQuote(j.v, res[i]);
          nQuotes++;
          if (d.status === "unmeasured") nUnmeasured++;
          if (d.status === "ok") ladders[vi].points[j.n - 1] = d.out;
          insQuote.run(runId, ticker, direction, sizeUsd, j.amt.toString(), ladders[vi].family,
            ladders[vi].kind, ladders[vi].id, j.n,
            d.out === null ? null : d.out.toString(), d.status, d.err ?? null);
        });

        let bestOut = null, bestId = null, bestFam = null, bestV3 = null, bestV4 = null, bestMk = null;
        ladders.forEach((L) => {
          const full = L.points[K_CHUNKS - 1];
          if (full === null) return;
          if (bestOut === null || full > bestOut) { bestOut = full; bestId = L.id; bestFam = L.family; }
          if (L.kind === "v3" && (bestV3 === null || full > bestV3)) bestV3 = full;
          if (L.kind === "v4" && (bestV4 === null || full > bestV4)) bestV4 = full;
          if (L.kind === "maker" && (bestMk === null || full > bestMk)) bestMk = full;
        });

        const split = greedySplit(ladders, amountIn, K_CHUNKS);

        const cellIx = priced.findIndex((x) => x.ticker === ticker) * SIZES_USD.length * 2
          + SIZES_USD.indexOf(sizeUsd) * 2 + (direction === "buy" ? 1 : 0);
        let kAll = { out: null, status: "skipped-rotation" }, kOn = { out: null, status: "skipped-rotation" };
        if (cellIx % KYBER_ROTATE === runId % KYBER_ROTATE) {
          kAll = await kyber(tokenIn, tokenOut, amountIn.toString(), null);
          recordKyber(runId, ticker, direction, sizeUsd, 0, kAll);
          await sleep(KYBER_PACE_MS);
          kOn = await kyber(tokenIn, tokenOut, amountIn.toString(), ONCHAIN_FAMILIES);
          recordKyber(runId, ticker, direction, sizeUsd, 1, kOn);
          await sleep(KYBER_PACE_MS);
        }

        const kstr = (k) => k.status + (k.families ? ` hops=${k.hops} rfq=${k.rfqShare}% [${k.families.join("|")}]`
                                                  : (k.cls ? ` [${k.cls}: ${k.err ?? ""}]` : ""));
        insAgg.run(runId, ticker, direction, sizeUsd, amountIn.toString(),
          bestOut?.toString() ?? null, bestId, bestFam,
          bestV3?.toString() ?? null, bestV4?.toString() ?? null, bestMk?.toString() ?? null,
          split.total > 0n ? split.total.toString() : null,
          process.env.PARTITIO_ROUTER ? "split_router" : "split_sim",
          JSON.stringify(split.legs), split.legs.length,
          kAll.out?.toString() ?? null, kstr(kAll),
          kOn.out?.toString() ?? null, kstr(kOn),
          null, "skipped");

        const vs = bestOut && split.total ? ((Number(split.total - bestOut) / Number(bestOut)) * 10000).toFixed(1) : "?";
        log(`  ${ticker} ${direction} $${sizeUsd}: best ${bestOut} split ${split.total} x${split.legs.length}  ${vs}bps  kyber ${kAll.out ?? kAll.status}`);
      }
    }
  }
  db.prepare("UPDATE run SET finished_at=? WHERE id=?").run(new Date().toISOString(), runId);
  log(`run ${runId} done: ${nQuotes} quotes, ${nUnmeasured} unmeasured`);
}

// ---- read-only JSON ----
http.createServer((req, res) => {
  const send = (code, obj) => { res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*" }); res.end(JSON.stringify(obj, null, 1)); };
  try {
    const u = new URL(req.url, "http://x");
    if (u.pathname === "/health") {
      const r = db.prepare("SELECT id,started_at,finished_at,block FROM run ORDER BY id DESC LIMIT 1").get();
      const unfinished = db.prepare("SELECT COUNT(*) c FROM run WHERE finished_at IS NULL").get().c;
      return send(200, { ok: true, inFlight, lastRun: r ?? null, unfinishedRuns: unfinished,
                         tickers: TICKERS.length, sizes: SIZES_USD });
    }
    if (u.pathname === "/latest") {
      const r = db.prepare("SELECT id FROM run WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1").get();
      if (!r) return send(200, { rows: [] });
      return send(200, { runId: r.id, rows: db.prepare("SELECT * FROM agg WHERE run_id=?").all(r.id) });
    }
    if (u.pathname === "/summary") {
      return send(200, {
        runs: db.prepare("SELECT COUNT(*) c FROM run WHERE finished_at IS NOT NULL").get().c,
        comparisons: db.prepare("SELECT COUNT(*) c FROM agg").get().c,
        quotes: db.prepare("SELECT COUNT(*) c FROM quote").get().c,
        unmeasured: db.prepare("SELECT COUNT(*) c FROM quote WHERE status='unmeasured'").get().c,
        refused: db.prepare("SELECT COUNT(*) c FROM quote WHERE status='refused'").get().c,
      });
    }
    send(404, { err: "not found", routes: ["/health", "/latest", "/summary"] });
  } catch (e) { send(500, { err: String(e.message || e) }); }
}).listen(PORT, () => log(`http on :${PORT}`));

// A run can exceed the interval: the Kyber leg is deliberately slow. Overlapping runs interleave
// writes and leave finished_at NULL forever, so the timer skips rather than starting a second one.
let inFlight = false;
let skipped = 0;
async function tick() {
  if (inFlight) {
    skipped++;
    log(`run still in flight, skipping this tick (${skipped} skipped since last completion)`);
    return;
  }
  inFlight = true;
  const t0 = Date.now();
  try { await runOnce(); }
  catch (e) { log("run failed:", e.message); }
  finally {
    inFlight = false;
    log(`run wall time ${((Date.now() - t0) / 1000).toFixed(0)}s, interval ${(INTERVAL_MS / 1000).toFixed(0)}s`);
    skipped = 0;
  }
}

log(`partitio-evidence starting: ${TICKERS.length} tickers x ${SIZES_USD.length} sizes, K=${K_CHUNKS}`);
tick();
setInterval(tick, INTERVAL_MS);
