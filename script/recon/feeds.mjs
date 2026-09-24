// Chainlink feed per ticker, read out of each Morpho market's ChainlinkOracleV2 wrapper.
// Selectors are computed with `cast sig` and asserted here rather than recalled — an earlier
// attempt used a remembered BASE_FEED_1 selector, resolved zero feeds, and looked like the
// oracles simply did not expose one.
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://robinhood-rpc.publicnode.com";
const SEL = {
  BASE_FEED_1: "0xf50a4718",
  QUOTE_FEED_1: "0x56095e11",
  description: "0x7284e416",
  latestRoundData: "0xfeaf968c",
  decimals: "0x313ce567",
};
const ZERO = "0x0000000000000000000000000000000000000000";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const w = (v, i) => v.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);
let id = 0;

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
const str = (v) => {
  if (!v || v.length < 130) return null;
  const len = parseInt(w(v, 1), 16);
  return Buffer.from(v.replace(/^0x/, "").slice(128, 128 + len * 2), "hex").toString("utf8");
};

(async () => {
  const m = JSON.parse(fs.readFileSync(new URL("./morpho.json", import.meta.url)));
  const byTicker = new Map();
  for (const mk of m.stockMarkets) if (mk.ticker && !byTicker.has(mk.ticker)) byTicker.set(mk.ticker, mk.oracle);
  const entries = [...byTicker.entries()];
  console.log(`oracles to read: ${entries.length}`);

  const feeds = {};
  for (let i = 0; i < entries.length; i += 25) {
    for (const { k, v } of await batch(entries.slice(i, i + 25).map(([t, o]) => ({ k: t, to: o, data: SEL.BASE_FEED_1 }))))
      if (v && v !== "0x") feeds[k] = "0x" + v.slice(26);
    await sleep(300);
  }
  const ok = Object.entries(feeds).filter(([, f]) => f && f !== ZERO);
  console.log(`feeds resolved: ${ok.length}`);
  if (!ok.length) { console.log("ABORT: no feeds resolved"); process.exit(1); }

  const meta = {};
  for (let i = 0; i < ok.length; i += 20) {
    const sl = ok.slice(i, i + 20);
    for (const { k, v } of await batch(sl.map(([t, f]) => ({ k: t, to: f, data: SEL.description }))))
      (meta[k] ||= {}).desc = str(v);
    for (const { k, v } of await batch(sl.map(([t, f]) => ({ k: t, to: f, data: SEL.decimals }))))
      (meta[k] ||= {}).decimals = v && v !== "0x" ? Number(BigInt(v)) : null;
    for (const { k, v } of await batch(sl.map(([t, f]) => ({ k: t, to: f, data: SEL.latestRoundData }))))
      if (v && v !== "0x") {
        (meta[k] ||= {}).answer = BigInt("0x" + w(v, 1)).toString();
        meta[k].updatedAt = Number(BigInt("0x" + w(v, 3)));
      }
    await sleep(300);
  }

  const now = Math.floor(Date.now() / 1000);
  const out = {};
  console.log();
  console.log("ticker  feed                                        description                 price      age(s)");
  for (const [t, f] of ok.sort()) {
    const md = meta[t] || {};
    const dec = md.decimals ?? 8;
    const px = md.answer ? Number(md.answer) / 10 ** dec : null;
    const age = md.updatedAt ? now - md.updatedAt : null;
    out[t] = { feed: f, desc: md.desc ?? null, decimals: dec, answer: md.answer ?? null,
               updatedAt: md.updatedAt ?? null, priceUsd: px };
    console.log(t.padEnd(7) + f + "  " + String(md.desc ?? "?").padEnd(26) +
      String(px === null ? "?" : px.toFixed(4)).padStart(10) + "  " + String(age ?? "?").padStart(7));
  }
  fs.writeFileSync(new URL("./chainlink-feeds.json", import.meta.url),
    JSON.stringify({ at: new Date().toISOString(), note: "prices already include ERC-8056 uiMultiplier per Robinhood docs; NEVER apply it again", feeds: out }, null, 1));
  console.log(`\nwrote chainlink-feeds.json — ${Object.keys(out).length} feeds`);
})();
