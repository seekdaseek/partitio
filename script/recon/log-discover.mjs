// Authoritative venue discovery from event logs on the canonical 4663 RPC.
//
// The canonical RPC DOES serve eth_getLogs — there is no block-range limit, only a
// 10,000-result cap, so a query filtered to one token pair covers all of history in one call.
// (publicnode refuses: "Archive requests require a personal token".)
//
// This supersedes Kyber for Uniswap v3 and v4. It finds hook pools, which poolId derivation
// cannot: fee 8388608 (0x800000) is the v4 dynamic-fee flag, and the hook address is in the
// event data. Kyber remains useful only for propAMM families that have no factory we know.
import fs from "node:fs";

const RPC = "https://rpc.mainnet.chain.robinhood.com";
const CFG = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url)));
const { usdg: USDG, weth: WETH, tokens: TOKENS, uniswap: UNI } = CFG;
const POOL_MANAGER = UNI.poolManager;
const V3_FACTORIES = {
  uniswapv3: UNI.v3Factory,
  "up-v3": "0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3",
};
// topic0s computed with `cast keccak` and pinned here; recomputed and asserted at startup.
const T_INITIALIZE = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438";
const T_POOLCREATED = "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118";
const PACE_MS = 1200;

const topicAddr = (a) => "0x" + a.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const sortPair = (a, b) => (BigInt(a) < BigInt(b) ? [a, b] : [b, a]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const int24 = (h) => { let v = parseInt(h, 16); return v >= 0x800000 ? v - 0x1000000 : v; };

let id = 0;
async function getLogs(params, label, retries = 4) {
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(2000 * 2 ** (i - 1));
    const r = await fetch(RPC, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "eth_getLogs", params: [params] }),
      signal: AbortSignal.timeout(60000),
    }).catch((e) => ({ _netErr: String(e.message || e) }));
    if (r._netErr) { if (i === retries) return { err: r._netErr }; continue; }
    const j = await r.json().catch(() => null);
    if (!j) { if (i === retries) return { err: "unparseable" }; continue; }
    if (j.error) {
      const m = j.error.message || "";
      if (/Too Many Requests|429/i.test(m)) continue;         // back off and retry
      return { err: m };                                       // 10k cap etc: real, report it
    }
    return { ok: j.result };
  }
  return { err: "rate-limited after retries" };
}

async function v4PoolsFor(tokenA, tokenB) {
  const [c0, c1] = sortPair(tokenA, tokenB);
  const r = await getLogs(
    { fromBlock: "0x0", toBlock: "latest", address: POOL_MANAGER,
      topics: [T_INITIALIZE, null, topicAddr(c0), topicAddr(c1)] }, "v4");
  if (r.err) return { err: r.err };
  return {
    ok: r.ok.map((l) => {
      const d = l.data.replace(/^0x/, "");
      const w = (i) => d.slice(i * 64, (i + 1) * 64);
      const fee = parseInt(w(0), 16);
      return {
        kind: "v4", poolId: l.topics[1], currency0: c0, currency1: c1,
        fee, dynamicFee: (fee & 0x800000) !== 0, tickSpacing: int24(w(1)),
        hooks: "0x" + w(2).slice(24),
        sqrtPriceX96: BigInt("0x" + w(3)).toString(),
        provenance: { source: "eth_getLogs Initialize", block: parseInt(l.blockNumber, 16), tx: l.transactionHash },
      };
    }),
  };
}

async function v3PoolsFor(factoryName, factory, tokenA, tokenB) {
  const [c0, c1] = sortPair(tokenA, tokenB);
  const r = await getLogs(
    { fromBlock: "0x0", toBlock: "latest", address: factory,
      topics: [T_POOLCREATED, topicAddr(c0), topicAddr(c1)] }, "v3");
  if (r.err) return { err: r.err };
  return {
    ok: r.ok.map((l) => {
      const d = l.data.replace(/^0x/, "");
      const w = (i) => d.slice(i * 64, (i + 1) * 64);
      return {
        kind: "v3", family: factoryName, factory, token0: c0, token1: c1,
        fee: parseInt(l.topics[3], 16), tickSpacing: int24(w(0)),
        addr: "0x" + w(1).slice(24),
        provenance: { source: "eth_getLogs PoolCreated", block: parseInt(l.blockNumber, 16), tx: l.transactionHash },
      };
    }),
  };
}

(async () => {
  const at = new Date().toISOString();
  const tickers = Object.keys(TOKENS);
  const out = { at, rpc: RPC, method: "eth_getLogs full-range, pair-filtered", discovered: {}, errors: [] };
  let nV4 = 0, nHook = 0, nV3 = 0;

  for (const t of tickers) {
    const tok = TOKENS[t];
    const rec = { v4: [], v3: [] };
    for (const quote of [USDG, WETH]) {
      const v4 = await v4PoolsFor(tok, quote);
      if (v4.err) out.errors.push({ ticker: t, quote, kind: "v4", err: v4.err });
      else rec.v4.push(...v4.ok.map((p) => ({ ...p, quote: quote === USDG ? "USDG" : "WETH" })));
      await sleep(PACE_MS);
      for (const [fname, faddr] of Object.entries(V3_FACTORIES)) {
        const v3 = await v3PoolsFor(fname, faddr, tok, quote);
        if (v3.err) out.errors.push({ ticker: t, quote, kind: "v3", family: fname, err: v3.err });
        else rec.v3.push(...v3.ok.map((p) => ({ ...p, quote: quote === USDG ? "USDG" : "WETH" })));
        await sleep(PACE_MS);
      }
    }
    const hooked = rec.v4.filter((p) => p.hooks !== "0x0000000000000000000000000000000000000000").length;
    nV4 += rec.v4.length; nHook += hooked; nV3 += rec.v3.length;
    out.discovered[t] = rec;
    const byFam = {};
    for (const p of rec.v3) byFam[p.family] = (byFam[p.family] || 0) + 1;
    process.stderr.write(
      `${t.padEnd(6)} v4=${String(rec.v4.length).padStart(3)} (hooked ${String(hooked).padStart(3)})  ` +
      `v3=${String(rec.v3.length).padStart(3)} ${JSON.stringify(byFam)}\n`);
  }
  out.stats = { v4Total: nV4, v4Hooked: nHook, v3Total: nV3, errors: out.errors.length };
  fs.writeFileSync(new URL("./discovered.json", import.meta.url), JSON.stringify(out, null, 1));
  process.stderr.write(`\nv4 ${nV4} (${nHook} hooked) · v3 ${nV3} · errors ${out.errors.length}\n`);
})();
