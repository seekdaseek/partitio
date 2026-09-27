// How often would the app's 2% default band REFUSE a trade?
//
// The evidence engine records what the venues quoted; it never recorded the Chainlink reference,
// so the reference is reconstructed here from ARCHIVE state at each run's own block. That is the
// only way to ask the question honestly: a floor computed against today's price tells you nothing
// about a fill quoted eighteen hours ago.
//
// Refused means: the best output partitio could actually deliver is below ref * (1 - band).
// Reported per ticker, per direction, split into US market-open and closed hours.

import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";

const DB = "/opt/partitio-evidence/partitio-v2.db";
const RPC = fs.readFileSync("/opt/partitio-evidence/qn_rpc", "utf8").trim();
const FEEDS = JSON.parse(fs.readFileSync("/opt/partitio-evidence/chainlink-feeds.json", "utf8")).feeds;
const BANDS = [200, 300, 500];

// The archive endpoint allows 15 requests per second and counts every call in a JSON-RPC batch
// individually. The first version of this script used 25-call batches and swallowed the resulting
// per-item rate-limit errors as nulls: it reported 157 of 666 references fetched and the surviving
// sample changed between runs, which is the same "a truncated batch reads as a thin market" failure
// the collector was just fixed for. Eight calls paced at 700ms is ~11/s with headroom, and a 429
// now backs off instead of dropping the row.
const MAX_BATCH = 8;
const PACE_MS = 700;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// US regular session in UTC: 13:30 - 20:00. A Saturday/Sunday run is closed whatever the clock says.
function isOpen(startedAt) {
  const d = new Date(startedAt.replace(" ", "T").replace(/Z?$/, "Z"));
  if (Number.isNaN(d.getTime())) return null;
  const dow = d.getUTCDay();
  if (dow === 0 || dow === 6) return false;
  const m = d.getUTCHours() * 60 + d.getUTCMinutes();
  return m >= 810 && m < 1200;
}

let id = 0;
let rateLimited = 0;
let hardFail = 0;
async function batch(calls, block) {
  const out = [];
  for (let i = 0; i < calls.length; i += MAX_BATCH) {
    const slice = calls.slice(i, i + MAX_BATCH);
    const body = slice.map((c) => ({
      jsonrpc: "2.0", id: ++id, method: "eth_call",
      params: [{ to: c.to, data: c.data }, "0x" + block.toString(16)],
    }));
    let got = null;
    for (let a = 0; a < 6 && !got; a++) {
      if (a) { rateLimited++; await sleep(1200 * a); }
      try {
        const r = await fetch(RPC, {
          method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify(body), signal: AbortSignal.timeout(30000),
        });
        if (r.status === 429) continue;
        const j = await r.json();
        if (!Array.isArray(j)) continue;
        // a partial rate-limit inside a 200 response is still a failure - retry the whole batch
        if (j.some((x) => x.error && /limit/i.test(x.error.message || ""))) continue;
        got = j;
      } catch { /* retry */ }
    }
    if (!got) { hardFail += slice.length; out.push(...slice.map(() => null)); await sleep(PACE_MS); continue; }
    const byId = new Map(got.map((x) => [x.id, x]));
    for (const b of body) {
      const x = byId.get(b.id);
      out.push(x && x.result && x.result !== "0x" ? x.result : null);
    }
    await sleep(PACE_MS);
  }
  return out;
}

const db = new DatabaseSync(DB, { readOnly: true });
// HEADLINE_MAX_RUN pins the series: the published headline is runs 1-245, and the collector keeps
// adding runs, so an unpinned re-run would silently publish different numbers.
const MAX_RUN = Number(process.env.HEADLINE_MAX_RUN || 1e12);
const runs = db.prepare("SELECT id, started_at, block FROM run WHERE block IS NOT NULL AND id <= ? ORDER BY id").all(MAX_RUN);
const tickers = [...new Set(db.prepare("SELECT DISTINCT ticker FROM agg").all().map((r) => r.ticker))].sort();

// token decimals, once, at head
const tokenAddr = JSON.parse(fs.readFileSync("/opt/partitio-evidence/tokens.json", "utf8")).tokens;
const decCalls = tickers.map((t) => ({ to: tokenAddr[t] || tokenAddr[t.toUpperCase()], data: "0x313ce567" }));
const head = runs[runs.length - 1].block;
const decRes = await batch(decCalls, head);
const tokenDec = {};
tickers.forEach((t, i) => { tokenDec[t] = decRes[i] ? Number(BigInt(decRes[i])) : 18; });

// the reference, per run per ticker, from archive state at that run's own block
const refAt = new Map();  // `${runId}|${ticker}` -> {price: bigint, feedDec: number}
let fetched = 0, missing = 0;
for (const r of runs) {
  const list = tickers.filter((t) => FEEDS[t]);
  const res = await batch(list.map((t) => ({ to: FEEDS[t].feed, data: "0xfeaf968c" })), r.block);
  list.forEach((t, i) => {
    const raw = res[i];
    if (!raw || raw.length < 130) { missing++; return; }
    const answer = BigInt("0x" + raw.slice(66, 130));
    if (answer <= 0n) { missing++; return; }
    refAt.set(`${r.id}|${t}`, { price: answer, feedDec: FEEDS[t].decimals });
    fetched++;
  });
  process.stderr.write(`run ${r.id} @ ${r.block}\r`);
}
const total = fetched + missing;
process.stderr.write(`\nreferences: ${fetched} fetched, ${missing} missing, ${rateLimited} retries, ${hardFail} gave up\n`);
console.log(`references: ${fetched}/${total} fetched (${((100 * fetched) / total).toFixed(1)}%)`);
if (missing / total > 0.02) {
  console.error(`REFUSING TO REPORT: ${missing}/${total} references missing. A decimated sample`);
  console.error("reads exactly like a thin market, which is the thing being measured.");
  process.exit(2);
}

const rows = db.prepare(`
  SELECT a.run_id, a.ticker, a.direction, a.size_usd, a.amount_in,
         a.best_venue_out, a.split_out, a.kyber_onchain_out, a.lifi_out, r.started_at
  FROM agg a JOIN run r ON r.id = a.run_id
  WHERE a.amount_in IS NOT NULL AND a.run_id <= ?`).all(MAX_RUN);

const big = (x) => { try { return x == null ? null : BigInt(x); } catch { return null; } };

const cells = [];
for (const row of rows) {
  const ref = refAt.get(`${row.run_id}|${row.ticker}`);
  if (!ref) continue;
  const open = isOpen(row.started_at);
  if (open === null) continue;
  const amountIn = big(row.amount_in);
  if (!amountIn || amountIn === 0n) continue;

  const sdec = BigInt(tokenDec[row.ticker] ?? 18);
  const fdec = BigInt(ref.feedDec);
  let refOut;
  if (row.direction === "buy") {
    refOut = (amountIn * 10n ** sdec * 10n ** fdec) / (10n ** 6n * ref.price);
  } else {
    refOut = (amountIn * ref.price * 10n ** 6n) / (10n ** sdec * 10n ** fdec);
  }
  if (refOut === 0n) continue;

  const partitio = [big(row.split_out), big(row.best_venue_out)].filter((x) => x && x > 0n);
  if (!partitio.length) continue;
  const bestPartitio = partitio.reduce((a, b) => (a > b ? a : b));
  const withAgg = [bestPartitio, big(row.kyber_onchain_out), big(row.lifi_out)]
    .filter((x) => x && x > 0n).reduce((a, b) => (a > b ? a : b));

  const devP = Number(((bestPartitio - refOut) * 10000n) / refOut);
  const devA = Number(((withAgg - refOut) * 10000n) / refOut);
  cells.push({ ...row, open, devP, devA });
}

// ------------------------------------------------------------------ report

const key = (c) => `${c.ticker}|${c.direction}|${c.open ? "open" : "closed"}`;
const groups = new Map();
for (const c of cells) {
  if (!groups.has(key(c))) groups.set(key(c), []);
  groups.get(key(c)).push(c);
}

const pct = (n, d) => (d === 0 ? "   -  " : ((100 * n) / d).toFixed(1).padStart(5) + "%");
const med = (xs) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : 0; };

console.log(`\ncells: ${cells.length}   runs: ${runs.length}   tickers: ${tickers.length}`);
console.log(`open-hours cells: ${cells.filter((c) => c.open).length}   closed: ${cells.filter((c) => !c.open).length}\n`);

for (const band of BANDS) {
  console.log(`=== refused at ${band} bps (partitio route alone | with the aggregator leg) ===`);
  console.log("ticker dir    hours   n    median bps   refused        refused+agg");
  const out = [];
  for (const [k, cs] of [...groups].sort()) {
    const [t, d, h] = k.split("|");
    const refP = cs.filter((c) => c.devP < -band).length;
    const refA = cs.filter((c) => c.devA < -band).length;
    out.push({ t, d, h, n: cs.length, m: med(cs.map((c) => c.devP)), refP, refA });
  }
  for (const r of out) {
    const flag = r.h === "open" && r.n >= 8 && (100 * r.refP) / r.n > 5 ? "  <-- OVER 5%" : "";
    console.log(
      `${r.t.padEnd(6)} ${r.d.padEnd(5)} ${r.h.padEnd(7)} ${String(r.n).padStart(3)}  ${String(r.m).padStart(8)}   ${pct(r.refP, r.n)}  ${pct(r.refA, r.n)}${flag}`
    );
  }
  const openCells = cells.filter((c) => c.open);
  const closedCells = cells.filter((c) => !c.open);
  console.log(`  ALL open   n=${openCells.length}  refused ${pct(openCells.filter((c) => c.devP < -band).length, openCells.length)}  with agg ${pct(openCells.filter((c) => c.devA < -band).length, openCells.length)}`);
  console.log(`  ALL closed n=${closedCells.length}  refused ${pct(closedCells.filter((c) => c.devP < -band).length, closedCells.length)}  with agg ${pct(closedCells.filter((c) => c.devA < -band).length, closedCells.length)}\n`);
}

// by size, at the app default
console.log("=== by trade size, 200 bps, open hours, partitio route alone ===");
for (const s of [...new Set(cells.map((c) => c.size_usd))].sort((a, b) => a - b)) {
  for (const d of ["buy", "sell"]) {
    const cs = cells.filter((c) => c.open && c.size_usd === s && c.direction === d);
    if (!cs.length) continue;
    console.log(`  $${String(s).padStart(6)} ${d.padEnd(5)} n=${String(cs.length).padStart(3)}  median ${String(med(cs.map((c) => c.devP))).padStart(6)} bps  refused ${pct(cs.filter((c) => c.devP < -200).length, cs.length)}`);
  }
}

// ------------------------------------------------------------------ the decisive cut
// Every per-ticker "over 5%" above is 25.0% on a multiple of 4. If that quarter is always the
// $500,000 rung, the band is not refusing a TICKER, it is refusing a SIZE.
console.log("\n=== ticker property or size property? (200 bps) ===");
for (const [lo, hi, label] of [[1000, 10000, "$1k - $10k"], [1000, 100000, "$1k - $100k"], [500000, 500000, "$500k only"]]) {
  for (const oh of [true, false]) {
    const cs = cells.filter((c) => c.open === oh && c.size_usd >= lo && c.size_usd <= hi);
    const ref = cs.filter((c) => c.devP < -200);
    const byT = {};
    for (const c of ref) byT[c.ticker] = (byT[c.ticker] || 0) + 1;
    console.log(`  ${label.padEnd(13)} ${(oh ? "open" : "closed").padEnd(7)} n=${String(cs.length).padStart(4)}  refused ${pct(ref.length, cs.length)}  median ${String(med(cs.map((c) => c.devP))).padStart(6)} bps   ${Object.entries(byT).sort((a,b)=>b[1]-a[1]).slice(0,8).map(([t,n])=>t+":"+n).join(" ")}`);
  }
}
console.log("\n=== per size rung, open hours, both directions pooled ===");
for (const s of [1000, 10000, 100000, 500000]) {
  const cs = cells.filter((c) => c.open && c.size_usd === s);
  const ref = cs.filter((c) => c.devP < -200);
  const byT = {};
  for (const c of ref) byT[c.ticker] = (byT[c.ticker] || 0) + 1;
  console.log(`  $${String(s).padStart(6)}  n=${String(cs.length).padStart(3)}  refused ${pct(ref.length, cs.length)}  median ${String(med(cs.map((c) => c.devP))).padStart(6)} bps   ${Object.entries(byT).sort((a,b)=>b[1]-a[1]).map(([t,n])=>t+":"+n).join(" ")}`);
}
console.log("\n=== the tickers that refuse at $1k-$100k, open hours: every cell ===");
const smallRef = cells.filter((c) => c.open && c.size_usd <= 100000 && c.devP < -200);
for (const t of [...new Set(smallRef.map((c) => c.ticker))].sort()) {
  const cs = cells.filter((c) => c.open && c.ticker === t && c.size_usd <= 100000).sort((a, b) => a.size_usd - b.size_usd || a.direction.localeCompare(b.direction));
  const byRung = {};
  for (const c of cs) {
    const k = `${c.size_usd}|${c.direction}`;
    byRung[k] = byRung[k] || { n: 0, r: 0, devs: [] };
    byRung[k].n++; byRung[k].devs.push(c.devP);
    if (c.devP < -200) byRung[k].r++;
  }
  for (const [k, v] of Object.entries(byRung)) {
    const [sz, d] = k.split("|");
    console.log(`  ${t.padEnd(5)} ${d.padEnd(4)} $${sz.padStart(6)}  n=${String(v.n).padStart(2)}  median ${String(med(v.devs)).padStart(6)} bps  refused ${pct(v.r, v.n)}`);
  }
}

// ------------------------------------------------------------------ HEADLINE: executable rows only
// A row counts only if its ladder is complete (transport_gaps = 0) AND the split clears the app's
// 200 bps Chainlink band at that run's own block: a gain on a trade the guard would refuse is not a
// saving anyone can have. Gains are per trade (medians), never summed across runs - a sum counts
// the same thin order book once per snapshot, which is how a $419M figure appears out of nothing.
{
  const rowsC = db.prepare("SELECT run_id, ticker, direction, size_usd, amount_in, transport_gaps, split_out, best_venue_out FROM agg WHERE run_id <= ?").all(MAX_RUN);
  const key = (r) => `${r.run_id}|${r.ticker}|${r.direction}|${r.size_usd}`;
  const dev = new Map(cells.map((c) => [`${c.run_id}|${c.ticker}|${c.direction}|${c.size_usd}`, c.devP]));
  // The label must name the runs that actually have Chainlink references, i.e. the run list read at
  // the START. It used to print MAX(id) of the run table at the END, so a query that started just
  // before run 246 labelled itself "runs to #246" while computing runs 1-245 - which is how the
  // first published caveat came to say 246.
  const lastRun = { m: Math.max(...runs.map((r) => r.id)), t: runs.reduce((a, r) => (r.id > a.id ? r : a)).started_at };

  // HEADLINE_DUMP=<dir>: write exactly the inputs this table was computed from, so the headline can
  // be recomputed offline by evidence/headline-offline.mjs with no database and no archive RPC.
  if (process.env.HEADLINE_DUMP) {
    const dir = process.env.HEADLINE_DUMP;
    fs.mkdirSync(dir, { recursive: true });
    const csv = (name, head, rowsOut) => fs.writeFileSync(`${dir}/${name}`, head + "\n" + rowsOut.map((r) => r.join(",")).join("\n") + "\n");
    csv("runs.csv", "id,started_at,block", runs.map((r) => [r.id, r.started_at, r.block]));
    csv("refs.csv", "run_id,ticker,answer,feed_decimals",
      [...refAt.entries()].map(([k, v]) => { const [rid, t] = k.split("|"); return [rid, t, v.price.toString(), v.feedDec]; }));
    csv("agg.csv", "run_id,ticker,direction,size_usd,amount_in,transport_gaps,split_out,best_venue_out",
      rowsC.map((r) => [r.run_id, r.ticker, r.direction, r.size_usd, r.amount_in, r.transport_gaps, r.split_out ?? "", r.best_venue_out ?? ""]));
    csv("token_decimals.csv", "ticker,decimals", Object.entries(tokenDec).map(([t, d]) => [t, d]));
    console.log(`dumped inputs to ${dir}`);
  }
  console.log(`\n=== HEADLINE (runs to #${lastRun.m}, ${lastRun.t}; complete ladder AND inside the 200 bps band) ===`);
  console.log("size      complete  in_band  split_beat_best  pct_in_band  median_usd_when_split  median_bps");
  for (const sz of [1000, 10000, 100000, 500000]) {
    const rs = rowsC.filter((r) => r.size_usd === sz && r.transport_gaps === 0 && r.split_out && r.best_venue_out && dev.has(key(r)));
    const inBand = rs.filter((r) => dev.get(key(r)) >= -200);
    const gains = inBand.filter((r) => BigInt(r.split_out) > BigInt(r.best_venue_out)).map((r) => {
      const s = Number(r.split_out), b = Number(r.best_venue_out);
      return r.direction === "sell" ? (s - b) / 1e6 : (sz * (s - b)) / s;   // buys valued at the split's own (lower) price
    }).sort((a, b) => a - b);
    const med = gains.length ? gains[Math.floor((gains.length - 1) / 2)] : 0;
    console.log(`$${String(sz).padEnd(8)} ${String(rs.length).padStart(8)} ${String(inBand.length).padStart(8)} ${String(gains.length).padStart(16)} ${((100 * gains.length) / Math.max(1, inBand.length)).toFixed(1).padStart(11)}% ${("$" + med.toFixed(2)).padStart(22)} ${((10000 * med) / sz).toFixed(1).padStart(11)}`);
  }
}
