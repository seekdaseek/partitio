// P0a: the problem, measured. Every stock-collateral Morpho market on 4663, its size, and every
// liquidation that has ever happened against one.
//
// Market id is keccak256(abi.encode(marketParams)) — the same derivation Morpho Blue uses, and it
// is asserted against the indexed id in the CreateMarket log before anything is trusted.
import fs from "node:fs";
import { keccak256, hexToBytes } from "./keccak.mjs";

const RPC = "https://rpc.mainnet.chain.robinhood.com";
const MORPHO = "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010";
const T_CREATE = "0xac4b2400f169220b0c0afdde7a0b32e775ba727ea1cb30b35f935cdaab8683ac";
const T_LIQ = "0xa4946ede45d0c6f06a0f5ce92c9ad3b4751452d2fe0e25010783bcab57a67e41";
const CFG = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url)));
const USDG = CFG.usdg.toLowerCase();
const BY_ADDR = new Map(Object.entries(CFG.tokens).map(([k, v]) => [v.toLowerCase(), k]));

const pad = (h) => String(h).replace(/^0x/, "").toLowerCase().padStart(64, "0");
const w = (d, i) => d.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);
const addr = (x) => "0x" + x.slice(24);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let id = 0;

async function rpc(method, params, retries = 4) {
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1500 * 2 ** (i - 1));
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }), signal: AbortSignal.timeout(60000) })
      .catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!j) continue;
    if (j.error) return { err: j.error.message };
    return { ok: j.result };
  }
  return { err: "rate-limited" };
}
async function batch(calls) {
  const out = new Map();
  for (let i = 0; i < calls.length; i += 30) {
    const slice = calls.slice(i, i + 30).map((c) => ({ jsonrpc: "2.0", id: ++id, method: "eth_call",
      params: [{ to: c.to, data: c.data }, "latest"], _k: c.k }));
    for (let a = 0; a < 5; a++) {
      if (a) await sleep(1500 * 2 ** (a - 1));
      const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify(slice.map(({ _k, ...rest }) => rest)), signal: AbortSignal.timeout(60000) }).catch(() => null);
      if (!r) continue;
      const j = await r.json().catch(() => null);
      if (!Array.isArray(j)) continue;
      const byId = new Map(j.map((x) => [x.id, x]));
      slice.forEach((s) => { const res = byId.get(s.id); out.set(s._k, res && !res.error ? res.result : null); });
      break;
    }
    await sleep(250);
  }
  return out;
}

(async () => {
  const at = new Date().toISOString();
  const head = parseInt((await rpc("eth_blockNumber", [])).ok, 16);

  const created = (await rpc("eth_getLogs", [{ fromBlock: "0x0", toBlock: "latest", address: MORPHO, topics: [T_CREATE] }])).ok;
  const liqs = (await rpc("eth_getLogs", [{ fromBlock: "0x0", toBlock: "latest", address: MORPHO, topics: [T_LIQ] }])).ok;
  console.error(`block ${head} · CreateMarket ${created.length} · Liquidate ${liqs.length}`);

  const markets = [];
  let idMismatch = 0;
  for (const l of created) {
    const d = l.data;
    const p = {
      loanToken: addr(w(d, 0)), collateralToken: addr(w(d, 1)),
      oracle: addr(w(d, 2)), irm: addr(w(d, 3)), lltv: BigInt("0x" + w(d, 4)),
    };
    const enc = pad(p.loanToken) + pad(p.collateralToken) + pad(p.oracle) + pad(p.irm) + pad(p.lltv.toString(16));
    const derived = keccak256(hexToBytes(enc));
    if (derived.toLowerCase() !== l.topics[1].toLowerCase()) { idMismatch++; continue; }
    markets.push({ ...p, id: derived, block: parseInt(l.blockNumber, 16), tx: l.transactionHash,
      ticker: BY_ADDR.get(p.collateralToken.toLowerCase()) || null });
  }
  console.error(`id derivation: ${markets.length} matched, ${idMismatch} MISMATCHED`);

  // stock collateral + USDG loan
  const stock = markets.filter((m) => m.ticker && m.loanToken.toLowerCase() === USDG);
  console.error(`stock-collateral USDG markets: ${stock.length} of ${markets.length}`);

  // market() state + oracle price()
  const SEL_MARKET = "0x5c60e39a";   // market(bytes32) - asserted below
  const SEL_PRICE = "0xa035b1fe";    // price()
  const calls = [];
  for (const m of stock) {
    calls.push({ k: "m:" + m.id, to: MORPHO, data: SEL_MARKET + pad(m.id) });
    calls.push({ k: "p:" + m.id, to: m.oracle, data: SEL_PRICE });
  }
  const res = await batch(calls);
  for (const m of stock) {
    const r = res.get("m:" + m.id);
    if (r && r !== "0x") {
      m.totalSupplyAssets = BigInt("0x" + w(r, 0)).toString();
      m.totalBorrowAssets = BigInt("0x" + w(r, 2)).toString();
      m.lastUpdate = Number(BigInt("0x" + w(r, 4)));
    } else m.stateErr = true;
    const pr = res.get("p:" + m.id);
    m.oraclePrice = pr && pr !== "0x" ? BigInt(pr).toString() : null;
  }

  // liquidations grouped by market
  const byId = new Map();
  for (const l of liqs) {
    const mid = l.topics[1].toLowerCase();
    const d = l.data;
    const e = byId.get(mid) || { count: 0, repaid: 0n, seized: 0n, badDebt: 0n, callers: new Set(), blocks: [] };
    e.count++;
    e.repaid += BigInt("0x" + w(d, 0));
    e.seized += BigInt("0x" + w(d, 2));
    e.badDebt += BigInt("0x" + w(d, 3));
    e.callers.add(addr(l.topics[2]));
    e.blocks.push(parseInt(l.blockNumber, 16));
    byId.set(mid, e);
  }

  const out = { at, block: head, morpho: MORPHO,
    counts: { createMarket: created.length, liquidate: liqs.length, idMismatch,
              marketsTotal: markets.length, stockUsdgMarkets: stock.length },
    stockMarkets: stock.map((m) => {
      const L = byId.get(m.id.toLowerCase());
      return { ...m, lltv: m.lltv.toString(),
        liquidations: L ? { count: L.count, repaid: L.repaid.toString(), seized: L.seized.toString(),
                            badDebt: L.badDebt.toString(), distinctCallers: L.callers.size,
                            firstBlock: Math.min(...L.blocks), lastBlock: Math.max(...L.blocks) } : null };
    }),
    liquidationsByMarket: [...byId.entries()].map(([k, v]) => ({ id: k, count: v.count,
      repaid: v.repaid.toString(), seized: v.seized.toString(), badDebt: v.badDebt.toString(),
      distinctCallers: v.callers.size })),
  };
  fs.writeFileSync(new URL("./morpho.json", import.meta.url), JSON.stringify(out, null, 1));

  // ---- report ----
  const fmt = (v, d) => v === null || v === undefined ? "?" : (Number(v) / 10 ** d).toFixed(2);
  const live = out.stockMarkets.filter((m) => m.totalSupplyAssets && BigInt(m.totalSupplyAssets) > 0n);
  console.error(`\nstock markets with supply > 0: ${live.length}`);
  console.error("ticker  LLTV%   breakeven%   supplyUSDG   borrowUSDG   liqs  oraclePrice");
  let totS = 0n, totB = 0n;
  for (const m of live.sort((a, b) => Number(BigInt(b.totalBorrowAssets || 0) - BigInt(a.totalBorrowAssets || 0)))) {
    const lltv = Number(m.lltv) / 1e18;
    const be = 0.3 * (1 - lltv) * 100;
    totS += BigInt(m.totalSupplyAssets || 0); totB += BigInt(m.totalBorrowAssets || 0);
    console.error(
      m.ticker.padEnd(7) + (lltv * 100).toFixed(1).padStart(5) + "  " + Math.min(be, 13.04).toFixed(2).padStart(9) +
      "   " + fmt(m.totalSupplyAssets, 6).padStart(10) + "   " + fmt(m.totalBorrowAssets, 6).padStart(10) +
      "   " + String(m.liquidations ? m.liquidations.count : 0).padStart(4) + "  " + (m.oraclePrice ?? "?"));
  }
  console.error(`\nTOTAL supply ${fmt(totS, 6)} USDG · borrow ${fmt(totB, 6)} USDG`);
  console.error(`liquidations touching ANY market: ${liqs.length}; touching stock markets: ` +
    out.stockMarkets.reduce((a, m) => a + (m.liquidations ? m.liquidations.count : 0), 0));
  console.error("\nwrote script/recon/morpho.json");
})();
