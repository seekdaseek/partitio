// Recompute the published headline from the committed snapshot. No database, no RPC, no keys.
//
//   node evidence/headline-offline.mjs
//
// The headline: "A $100,000 stock-token order on Robinhood Chain sent to the best single pool left
// a median $199 on the table in 6,329 of 7,493 executable quotes."
//
// evidence/headline.mjs produced it on the server, from the evidence database and from Chainlink
// answers read out of ARCHIVE state at each run's own block. With HEADLINE_DUMP set it wrote down
// exactly those inputs, and they are committed in evidence/snapshot-runs-1-245/:
//   agg.csv             every quote row: size, direction, the split's output, the best single pool's
//   refs.csv            the Chainlink answer for every run and ticker, at that run's block
//   runs.csv            run ids, start times and blocks
//   token_decimals.csv  stock token decimals, read on-chain
// This file repeats headline.mjs's arithmetic on them, integer for integer.
//
// A row is EXECUTABLE when its ladder is complete (no rung lost to RPC failure) and the better of
// the split and the best single pool sits inside the 200 bps Chainlink band the app signs - a gain
// on a trade the contract would refuse is not a gain anyone could have had. Gains are per trade and
// medians, never sums. On a buy the extra stock is valued at the split's own price, the lower one.
// These are quoted outputs, not executed trades.

import fs from "node:fs";
import path from "node:path";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const DIR = process.argv[2] || path.join(HERE, "snapshot-runs-1-245");

function readCsv(name) {
  const [head, ...lines] = fs.readFileSync(path.join(DIR, name), "utf8").trim().split("\n");
  const cols = head.split(",");
  return lines.map((l) => Object.fromEntries(l.split(",").map((v, i) => [cols[i], v])));
}

const runs = readCsv("runs.csv");
const refs = readCsv("refs.csv");
const agg = readCsv("agg.csv");
const tokenDec = Object.fromEntries(readCsv("token_decimals.csv").map((r) => [r.ticker, Number(r.decimals)]));

const refAt = new Map(refs.map((r) => [`${r.run_id}|${r.ticker}`, { price: BigInt(r.answer), feedDec: Number(r.feed_decimals) }]));
const startedAt = new Map(runs.map((r) => [r.id, r.started_at]));
const big = (x) => { try { return x === "" || x == null ? null : BigInt(x); } catch { return null; } };

// the same deviation headline.mjs computes: the better on-chain route against the Chainlink reference
const dev = new Map();
for (const row of agg) {
  if (!startedAt.has(row.run_id)) continue;                  // a run with no recorded block has no reference
  const ref = refAt.get(`${row.run_id}|${row.ticker}`);
  if (!ref) continue;
  const amountIn = big(row.amount_in);
  if (!amountIn || amountIn === 0n) continue;
  const sdec = BigInt(tokenDec[row.ticker] ?? 18);
  const fdec = BigInt(ref.feedDec);
  const refOut = row.direction === "buy"
    ? (amountIn * 10n ** sdec * 10n ** fdec) / (10n ** 6n * ref.price)
    : (amountIn * ref.price * 10n ** 6n) / (10n ** sdec * 10n ** fdec);
  if (refOut === 0n) continue;
  const outs = [big(row.split_out), big(row.best_venue_out)].filter((x) => x && x > 0n);
  if (!outs.length) continue;
  const best = outs.reduce((a, b) => (a > b ? a : b));
  dev.set(`${row.run_id}|${row.ticker}|${row.direction}|${row.size_usd}`, Number(((best - refOut) * 10000n) / refOut));
}

const last = runs.reduce((a, r) => (Number(r.id) > Number(a.id) ? r : a));
console.log(`HEADLINE, recomputed offline from ${path.relative(process.cwd(), DIR) || DIR}`);
console.log(`runs ${runs[0].id}-${last.id}, ${runs[0].started_at} to ${last.started_at}; ${agg.length} quote rows, ${refs.length} Chainlink references`);
console.log("size      complete  in_band  split_beat_best  pct_in_band  median_usd_when_split  median_bps");
for (const sz of [1000, 10000, 100000, 500000]) {
  const key = (r) => `${r.run_id}|${r.ticker}|${r.direction}|${r.size_usd}`;
  const rs = agg.filter((r) => Number(r.size_usd) === sz && Number(r.transport_gaps) === 0
    && r.split_out && r.best_venue_out && dev.has(key(r)));
  const inBand = rs.filter((r) => dev.get(key(r)) >= -200);
  const gains = inBand.filter((r) => BigInt(r.split_out) > BigInt(r.best_venue_out)).map((r) => {
    const s = Number(r.split_out), b = Number(r.best_venue_out);
    return r.direction === "sell" ? (s - b) / 1e6 : (sz * (s - b)) / s;
  }).sort((a, b) => a - b);
  const med = gains.length ? gains[Math.floor((gains.length - 1) / 2)] : 0;
  console.log(`$${String(sz).padEnd(8)} ${String(rs.length).padStart(8)} ${String(inBand.length).padStart(8)} ${String(gains.length).padStart(16)} ${((100 * gains.length) / Math.max(1, inBand.length)).toFixed(1).padStart(11)}% ${("$" + med.toFixed(2)).padStart(22)} ${((10000 * med) / sz).toFixed(1).padStart(11)}`);
}
