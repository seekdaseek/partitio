// Turn raw discovery into a registry. Standing rule: NO BYTECODE AT THE ADDRESS, NO VENUE.
//
// Nothing enters the registry on the strength of a log or a Kyber route. Each candidate must
// answer on-chain for itself:
//   v3  — eth_getCode non-empty, then token0/token1/fee/tickSpacing read back and matched
//         against the discovery record, then liquidity.
//   v4  — StateView.getSlot0 (initialised: sqrtPriceX96 != 0) and getLiquidity. A v4 pool is
//         state inside PoolManager, so "bytecode at the address" is PoolManager's, and the
//         hook address (when non-zero) must itself be a contract or the pool is unroutable.
// Provenance for every kept venue is carried through from discovery.
import fs from "node:fs";

const RPC = "https://rpc.mainnet.chain.robinhood.com";
const CFG = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url)));
const { uniswap: UNI } = CFG;
const ZERO = "0x0000000000000000000000000000000000000000";
const BATCH = 40;
const PACE_MS = 250;

const SEL = {                      // verified with `cast sig` in script/recon/selectors.txt
  token0: "0x0dfe1681", token1: "0xd21220a7", fee: "0xddca3f43", tickSpacing: "0xd0c93a7c",
  liquidity: "0x1a686502", getSlot0: "0x0000", getLiquidityV4: "0x0000",
};
// StateView selectors differ from the pool ones; filled from argv to stay honest about provenance.
SEL.getSlot0 = process.env.SEL_GETSLOT0;
SEL.getLiquidityV4 = process.env.SEL_GETLIQUIDITY;

const pad = (h) => h.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const toAddr = (w) => "0x" + w.slice(-40);
const wordAt = (d, i) => d.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);

let rpcId = 0;
async function rpcBatch(calls, retries = 5) {
  const body = calls.map((c) => ({
    jsonrpc: "2.0", id: ++rpcId,
    method: c.method || "eth_call",
    params: c.method === "eth_getCode" ? [c.to, "latest"] : [{ to: c.to, data: c.data }, "latest"],
  }));
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1500 * 2 ** (i - 1));
    const r = await fetch(RPC, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body), signal: AbortSignal.timeout(60000),
    }).catch((e) => ({ _err: String(e.message || e) }));
    if (r._err) continue;
    if (r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!Array.isArray(j)) continue;
    const byId = new Map(j.map((x) => [x.id, x]));
    return body.map((b) => {
      const res = byId.get(b.id);
      if (!res || res.error) return { err: res?.error?.message || "missing" };
      return { ok: res.result };
    });
  }
  return calls.map(() => ({ err: "rate-limited after retries" }));
}

async function runBatched(items, makeCall) {
  const out = [];
  for (let i = 0; i < items.length; i += BATCH) {
    const slice = items.slice(i, i + BATCH);
    const res = await rpcBatch(slice.map(makeCall));
    out.push(...res);
    if (i + BATCH < items.length) await sleep(PACE_MS);
    process.stderr.write(`\r    verified ${Math.min(i + BATCH, items.length)}/${items.length}   `);
  }
  process.stderr.write("\n");
  return out;
}

(async () => {
  if (!SEL.getSlot0 || !SEL.getLiquidityV4) {
    console.error("SEL_GETSLOT0 / SEL_GETLIQUIDITY must be supplied (computed by cast sig)");
    process.exit(1);
  }
  const disc = JSON.parse(fs.readFileSync(new URL("./discovered.json", import.meta.url)));
  const tickers = Object.keys(disc.discovered);

  const v4All = [], v3All = [];
  for (const t of tickers) {
    for (const p of disc.discovered[t].v4) v4All.push({ ...p, ticker: t });
    for (const p of disc.discovered[t].v3) v3All.push({ ...p, ticker: t });
  }
  console.error(`candidates: v4 ${v4All.length}, v3 ${v3All.length}`);

  // ---- v4 pass 1: active liquidity (cheapest discriminator; most hook pools are dead) ----
  console.error("v4: reading getLiquidity");
  const v4Liq = await runBatched(v4All, (p) => ({ to: UNI.stateView, data: SEL.getLiquidityV4 + pad(p.poolId) }));
  for (let i = 0; i < v4All.length; i++) {
    const r = v4Liq[i];
    v4All[i].liquidity = r.ok && r.ok !== "0x" ? BigInt(r.ok).toString() : null;
    v4All[i].liqErr = r.err || null;
  }
  const v4Live = v4All.filter((p) => p.liquidity && BigInt(p.liquidity) > 0n);
  console.error(`v4 with active liquidity: ${v4Live.length} of ${v4All.length}`);

  // ---- v4 pass 2: slot0 on the live ones ----
  console.error("v4: reading getSlot0 on live pools");
  const v4Slot = await runBatched(v4Live, (p) => ({ to: UNI.stateView, data: SEL.getSlot0 + pad(p.poolId) }));
  for (let i = 0; i < v4Live.length; i++) {
    const r = v4Slot[i];
    if (r.ok && r.ok !== "0x") {
      v4Live[i].sqrtPriceX96Live = BigInt("0x" + wordAt(r.ok, 0)).toString();
      let tick = parseInt(wordAt(r.ok, 1), 16); if (tick >= 0x800000) tick -= 0x1000000;
      v4Live[i].tickLive = tick;
      v4Live[i].lpFee = parseInt(wordAt(r.ok, 3), 16);
    } else v4Live[i].slot0Err = r.err || "empty";
  }

  // ---- v4 pass 3: every non-zero hook must itself be a contract ----
  const hooks = [...new Set(v4Live.map((p) => p.hooks).filter((h) => h !== ZERO))];
  console.error(`v4: checking ${hooks.length} distinct hook contracts`);
  const hookCode = await runBatched(hooks, (h) => ({ to: h, method: "eth_getCode" }));
  const hookOk = new Map();
  hooks.forEach((h, i) => hookOk.set(h, !!(hookCode[i].ok && hookCode[i].ok.length > 2)));

  // ---- v3: bytecode first, then read the pool's own accessors back ----
  console.error("v3: eth_getCode");
  const v3Code = await runBatched(v3All, (p) => ({ to: p.addr, method: "eth_getCode" }));
  const v3WithCode = [];
  for (let i = 0; i < v3All.length; i++) {
    const c = v3Code[i];
    if (c.ok && c.ok.length > 2) { v3All[i].codeChars = c.ok.length; v3WithCode.push(v3All[i]); }
    else v3All[i].rejected = "no bytecode";
  }
  console.error(`v3 with bytecode: ${v3WithCode.length} of ${v3All.length}`);

  console.error("v3: reading token0 / fee / liquidity back");
  const [t0s, fees, liqs] = [
    await runBatched(v3WithCode, (p) => ({ to: p.addr, data: SEL.token0 })),
    await runBatched(v3WithCode, (p) => ({ to: p.addr, data: SEL.fee })),
    await runBatched(v3WithCode, (p) => ({ to: p.addr, data: SEL.liquidity })),
  ];
  for (let i = 0; i < v3WithCode.length; i++) {
    const p = v3WithCode[i];
    p.token0Live = t0s[i].ok ? toAddr(t0s[i].ok) : null;
    p.feeLive = fees[i].ok && fees[i].ok !== "0x" ? parseInt(fees[i].ok, 16) : null;
    p.liquidity = liqs[i].ok && liqs[i].ok !== "0x" ? BigInt(liqs[i].ok).toString() : null;
    p.matchesLog =
      p.token0Live && p.token0Live.toLowerCase() === p.token0.toLowerCase() && p.feeLive === p.fee;
  }

  const registry = {
    at: new Date().toISOString(),
    rule: "no bytecode at the address, no venue",
    discoveredAt: disc.at,
    v4: v4Live.map((p) => ({
      kind: "v4", ticker: p.ticker, quote: p.quote, poolId: p.poolId,
      currency0: p.currency0, currency1: p.currency1, fee: p.fee, dynamicFee: p.dynamicFee,
      tickSpacing: p.tickSpacing, hooks: p.hooks, hookIsContract: p.hooks === ZERO ? null : hookOk.get(p.hooks),
      liquidity: p.liquidity, tick: p.tickLive, lpFee: p.lpFee, provenance: p.provenance,
    })).filter((p) => p.hooks === ZERO || p.hookIsContract),
    v3: v3WithCode.filter((p) => p.matchesLog && p.liquidity && BigInt(p.liquidity) > 0n).map((p) => ({
      kind: "v3", family: p.family, ticker: p.ticker, quote: p.quote, addr: p.addr,
      token0: p.token0, token1: p.token1, fee: p.fee, tickSpacing: p.tickSpacing,
      codeChars: p.codeChars, liquidity: p.liquidity, provenance: p.provenance,
    })),
    rejected: {
      v4NoLiquidity: v4All.length - v4Live.length,
      v4HookNotContract: v4Live.filter((p) => p.hooks !== ZERO && !hookOk.get(p.hooks)).length,
      v3NoBytecode: v3All.filter((p) => p.rejected).length,
      v3MismatchOrIdle: v3WithCode.filter((p) => !(p.matchesLog && p.liquidity && BigInt(p.liquidity) > 0n)).length,
    },
  };
  fs.writeFileSync(new URL("./registry.json", import.meta.url), JSON.stringify(registry, null, 1));
  console.error(`\nregistry: v4 ${registry.v4.length}, v3 ${registry.v3.length}`);
  console.error(`rejected: ${JSON.stringify(registry.rejected)}`);
})();
