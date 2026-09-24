// PRIVATE, read-only. Does any live Morpho market price its collateral wrongly?
//
// Method: compare each market's oracle.price() against the collateral asset's own Chainlink feed.
// This works for every oracle implementation, including the ones that do not expose BASE_FEED_1,
// and it tests the thing that actually matters — the number the protocol uses — rather than the
// oracle's internal wiring.
//
// price() is scaled 1e36 * 10^(loanDecimals - collateralDecimals) = 1e24 for USDG(6)/stock(18).
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://robinhood-rpc.publicnode.com";
const SEL = { price: "0xa035b1fe", description: "0x7284e416", latestRoundData: "0xfeaf968c", BASE_FEED_1: "0xf50a4718" };
const ZERO = "0x0000000000000000000000000000000000000000";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const w = (v, i) => v.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);
const str = (v) => { if (!v || v.length < 130) return null;
  const len = parseInt(w(v, 1), 16);
  return Buffer.from(v.replace(/^0x/, "").slice(128, 128 + len * 2), "hex").toString("utf8"); };
let id = 0;

// Tested against 11 known descriptions before use — see the extractor test in the session log.
function assetOf(desc) {
  if (!desc) return null;
  if (/uniswap/i.test(desc)) return "__POOL__";
  let d = desc.toUpperCase().replace(/\s+/g, " ").trim();
  d = d.replace(/\s*[\/-]\s*USD\s*$/, "").replace(/^ROBINHOOD\s+/, "").replace(/^RH/, "");
  return d.trim();
}
function selfTest() {
  const cases = [["Robinhood AAPL / USD", "AAPL"], ["RHTSLA / USD", "TSLA"], ["Robinhood DELL-USD", "DELL"],
                 ["Robinhood CRCL / USD", "CRCL"], ["Uniswap V3 Pool Price in USD", "__POOL__"], ["RHMU / USD", "MU"]];
  for (const [d, want] of cases) if (assetOf(d) !== want) throw new Error(`assetOf broken on ${d}`);
}

async function batch(reqs, retries = 4) {
  const body = reqs.map((r) => ({ jsonrpc: "2.0", id: ++id, method: "eth_call",
    params: [{ to: r.to, data: r.data }, "latest"], _k: r.k }));
  for (let a = 0; a <= retries; a++) {
    if (a) await sleep(1500 * 2 ** (a - 1));
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body.map(({ _k, ...x }) => x)), signal: AbortSignal.timeout(60000) }).catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!Array.isArray(j)) continue;
    const m = new Map(j.map((x) => [x.id, x]));
    return body.map((b) => { const z = m.get(b.id); return { k: b._k, v: z && !z.error ? z.result : null }; });
  }
  return reqs.map((r) => ({ k: r.k, v: null }));
}

(async () => {
  selfTest();
  const mm = JSON.parse(fs.readFileSync(new URL("./morpho.json", import.meta.url)));
  const cl = JSON.parse(fs.readFileSync(new URL("./chainlink-feeds.json", import.meta.url))).feeds;
  const live = mm.stockMarkets.filter((m) => m.totalSupplyAssets && BigInt(m.totalSupplyAssets) > 0n);

  // reference price per ticker, from its own Chainlink feed
  const ref = {};
  for (const [t, f] of Object.entries(cl)) if (f.priceUsd) ref[t] = { px: f.priceUsd, feed: f.feed, desc: f.desc };
  // TSLA's feed came from the sampler cross-check
  ref.TSLA ??= { px: null, feed: "0x4a1166a659a55625345e9515b32adecea5547c38", desc: "RHTSLA / USD" };

  // oracle.price() for every live market, and BASE_FEED_1 where exposed
  const oracles = [...new Set(live.map((m) => m.oracle))];
  const px = {}, bf = {};
  for (let i = 0; i < oracles.length; i += 25) {
    const sl = oracles.slice(i, i + 25);
    for (const { k, v } of await batch(sl.map((o) => ({ k: o, to: o, data: SEL.price }))))
      if (v && v !== "0x") px[k] = BigInt(v);
    for (const { k, v } of await batch(sl.map((o) => ({ k: o, to: o, data: SEL.BASE_FEED_1 }))))
      if (v && v !== "0x") bf[k] = "0x" + v.slice(26);
    await sleep(250);
  }
  const feeds = [...new Set(Object.values(bf).filter((f) => f && f !== ZERO))];
  const fdesc = {};
  for (let i = 0; i < feeds.length; i += 20) {
    for (const { k, v } of await batch(feeds.slice(i, i + 20).map((f) => ({ k: f, to: f, data: SEL.description }))))
      fdesc[k] = str(v);
    await sleep(250);
  }

  const rows = [];
  for (const m of live) {
    const p = px[m.oracle];
    const oraclePx = p ? Number(p) / 1e24 : null;          // USDG per collateral token
    const r = ref[m.ticker];
    const dev = oraclePx && r?.px ? (oraclePx - r.px) / r.px * 100 : null;
    const feed = bf[m.oracle], desc = feed && feed !== ZERO ? fdesc[feed] : null;
    const named = desc ? assetOf(desc) : null;
    rows.push({ id: m.id, ticker: m.ticker, lltv: m.lltv, oracle: m.oracle,
      supply: m.totalSupplyAssets, borrow: m.totalBorrowAssets,
      oraclePx, refPx: r?.px ?? null, devPct: dev, feed: feed ?? null, feedDesc: desc,
      feedNamesAsset: named, nameMismatch: named && named !== "__POOL__" && named !== m.ticker,
      poolDerived: named === "__POOL__" });
  }

  const f6 = (v) => (Number(v) / 1e6).toFixed(2);
  const bad = rows.filter((r) => r.devPct !== null && Math.abs(r.devPct) > 5);
  const nameBad = rows.filter((r) => r.nameMismatch);
  const pool = rows.filter((r) => r.poolDerived);

  console.log(`live markets: ${rows.length}`);
  console.log(`\n=== PRICE DEVIATION > 5% vs the collateral's own feed: ${bad.length} ===`);
  for (const r of bad.sort((a, b) => Number(b.supply) - Number(a.supply)))
    console.log(`  ${r.ticker.padEnd(6)} oracle ${r.oraclePx?.toFixed(4).padStart(11)}  ref ${String(r.refPx?.toFixed(4)).padStart(11)}  dev ${r.devPct.toFixed(1).padStart(8)}%  supply ${f6(r.supply).padStart(12)}  borrow ${f6(r.borrow).padStart(9)}`);
  console.log(`\n=== FEED NAMES A DIFFERENT ASSET: ${nameBad.length} ===`);
  for (const r of nameBad)
    console.log(`  ${r.ticker.padEnd(6)} feed "${r.feedDesc}" names ${r.feedNamesAsset}  supply ${f6(r.supply)}  borrow ${f6(r.borrow)}  ${r.id.slice(0, 18)}…`);
  console.log(`\n=== POOL-DERIVED ORACLE: ${pool.length} ===`);
  for (const r of pool)
    console.log(`  ${r.ticker.padEnd(6)} supply ${f6(r.supply).padStart(10)} borrow ${f6(r.borrow).padStart(8)}  ${r.id.slice(0, 18)}…`);
  const noPx = rows.filter((r) => r.oraclePx === null);
  console.log(`\noracles whose price() did not read: ${noPx.length}`);

  fs.writeFileSync(new URL("./oracle-audit.json", import.meta.url),
    JSON.stringify({ at: new Date().toISOString(), rows, bad, nameBad, pool }, null, 1));
  console.log("wrote script/recon/oracle-audit.json");
})();
