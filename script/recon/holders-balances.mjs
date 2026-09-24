// G2 part 2: for every address the scan found, can it afford to move its own position?
//
// Uses UniswapInterfaceMulticall (0x282a…f0a3, verified against a direct balanceOf before use)
// to fold ~120 balanceOf calls into one eth_call, otherwise this is ~950k RPC calls.
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const MC = "0x282a3c4d320cc7f0d5eaf56b8029e4b88338f0a3";
const SEL_MULTICALL = "0x1749e1e3";
const SEL_BALANCEOF = "0x70a08231";
const SEL_QUOTE_V3 = "0xc6a5026a";
const QUOTER_V2 = "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7";
const CFG = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url)));
const USDG = CFG.usdg;
const PER_MULTICALL = 200;
const PACE = 250;

const pad = (h) => String(h).replace(/^0x/, "").toLowerCase().padStart(64, "0");
const padInt = (n) => pad(BigInt(n).toString(16));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const w = (d, i) => d.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);
let id = 0;

async function rpcBatch(reqs, retries = 5) {
  const body = reqs.map((r) => ({ jsonrpc: "2.0", id: ++id, method: r.method, params: r.params, _k: r.k }));
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(2000 * 2 ** (i - 1));
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body.map(({ _k, ...rest }) => rest)), signal: AbortSignal.timeout(90000) }).catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!Array.isArray(j)) continue;
    const byId = new Map(j.map((x) => [x.id, x]));
    return body.map((b) => { const res = byId.get(b.id); return { k: b._k, v: res && !res.error ? res.result : null }; });
  }
  return reqs.map((r) => ({ k: r.k, v: null }));
}

// encode multicall((target,gasLimit,callData)[])
function encodeMulticall(calls) {
  const n = calls.length;
  let head = padInt(0x20) + padInt(n);
  const offsets = [];
  let cur = n * 32;
  const tails = [];
  for (const c of calls) {
    offsets.push(cur);
    const cd = c.data.replace(/^0x/, "");
    const words = Math.ceil(cd.length / 64);
    const tail = pad(c.target) + padInt(200000) + padInt(0x60) + padInt(cd.length / 2) + cd.padEnd(words * 64, "0");
    tails.push(tail);
    cur += tail.length / 2;
  }
  return SEL_MULTICALL + head + offsets.map((o) => padInt(o)).join("") + tails.join("");
}

function decodeMulticall(ret, n) {
  // (uint256 blockNumber, (bool success, uint256 gasUsed, bytes returnData)[] returnData)
  const d = ret.replace(/^0x/, "");
  const arrOff = parseInt(w(d, 1), 16) * 2;
  const out = [];
  const count = parseInt(d.slice(arrOff, arrOff + 64), 16);
  const base = arrOff + 64;
  for (let i = 0; i < Math.min(count, n); i++) {
    const off = parseInt(d.slice(base + i * 64, base + (i + 1) * 64), 16) * 2;
    const s = base + off;
    const success = parseInt(d.slice(s, s + 64), 16) === 1;
    const rdOff = parseInt(d.slice(s + 128, s + 192), 16) * 2;
    const rdStart = s + 128 + rdOff;
    const rdLen = parseInt(d.slice(rdStart, rdStart + 64), 16);
    const rd = d.slice(rdStart + 64, rdStart + 64 + rdLen * 2);
    out.push(success && rd.length >= 64 ? BigInt("0x" + rd.slice(0, 64)) : null);
  }
  return out;
}

(async () => {
  const raw = JSON.parse(fs.readFileSync(new URL("./holders-raw.json", import.meta.url)));
  const addrs = raw.addresses;
  const tickers = Object.keys(CFG.tokens);
  console.error(`addresses ${addrs.length} · tokens ${tickers.length} + USDG`);

  // ---- 1 unit price per token, from QuoterV2 ----
  const priceReqs = tickers.map((t) => ({ k: t, method: "eth_call",
    params: [{ to: QUOTER_V2, data: SEL_QUOTE_V3 + pad(CFG.tokens[t]) + pad(USDG) + padInt(10n ** 18n) + padInt(500) + pad("0") }, "latest"] }));
  const prices = {};
  for (let i = 0; i < priceReqs.length; i += 25) {
    for (const { k, v } of await rpcBatch(priceReqs.slice(i, i + 25))) {
      prices[k] = v && v !== "0x" ? Number(BigInt("0x" + w(v, 0))) / 1e6 : null;
    }
    await sleep(PACE);
  }
  // retry the ones the 500 tier could not price, at 3000
  const missing = tickers.filter((t) => !prices[t]);
  if (missing.length) {
    const r2 = missing.map((t) => ({ k: t, method: "eth_call",
      params: [{ to: QUOTER_V2, data: SEL_QUOTE_V3 + pad(CFG.tokens[t]) + pad(USDG) + padInt(10n ** 18n) + padInt(3000) + pad("0") }, "latest"] }));
    for (let i = 0; i < r2.length; i += 25) {
      for (const { k, v } of await rpcBatch(r2.slice(i, i + 25))) {
        if (v && v !== "0x") prices[k] = Number(BigInt("0x" + w(v, 0))) / 1e6;
      }
      await sleep(PACE);
    }
  }
  const priced = tickers.filter((t) => prices[t]);
  console.error(`priced ${priced.length}/${tickers.length} tokens`);

  // ---- ETH balances for every address ----
  const eth = new Map();
  for (let i = 0; i < addrs.length; i += 30) {
    const slice = addrs.slice(i, i + 30);
    for (const { k, v } of await rpcBatch(slice.map((a) => ({ k: a, method: "eth_getBalance", params: [a, "latest"] })))) {
      eth.set(k, v ? BigInt(v) : null);
    }
    if (i % 3000 === 0) process.stderr.write(`\r  eth ${i}/${addrs.length}   `);
    await sleep(PACE);
  }
  process.stderr.write(`\r  eth ${addrs.length}/${addrs.length}   \n`);
  fs.writeFileSync(new URL("./holders-eth.json", import.meta.url), JSON.stringify(
    { at: new Date().toISOString(), head: raw.head, window: raw.window,
      eth: Object.fromEntries([...eth.entries()].map(([k, v]) => [k, (v ?? 0n).toString()])) }));
  console.error("  wrote holders-eth.json");

  // Only wallets that CANNOT pay for approve+swap need their tokens priced: the question is
  // "who is stuck", and a wallet with gas is not stuck whatever it holds. This is the difference
  // between ~833k balance reads and a fraction of that.
  const GAS = BigInt(process.env.GAS_WEI || 11370000000000);
  const poor = addrs.filter((a) => (eth.get(a) ?? 0n) < GAS);
  console.error(`  below gas threshold: ${poor.length} of ${addrs.length} — only these get priced`);

  // ---- token balances via multicall ----
  const assets = [...priced.map((t) => ({ sym: t, addr: CFG.tokens[t], dec: 18, px: prices[t] })),
                  { sym: "USDG", addr: USDG, dec: 6, px: 1 }];
  const bal = new Map();     // addr -> {sym: bigint}
  const pairs = [];
  for (const a of poor) for (const as of assets) pairs.push({ a, as });
  console.error(`balance reads: ${pairs.length} via multicall`);

  for (let i = 0; i < pairs.length; i += PER_MULTICALL * 25) {
    const chunk = pairs.slice(i, i + PER_MULTICALL * 25);
    const reqs = [];
    for (let j = 0; j < chunk.length; j += PER_MULTICALL) {
      const sub = chunk.slice(j, j + PER_MULTICALL);
      reqs.push({ k: i + j, method: "eth_call",
        params: [{ to: MC, data: encodeMulticall(sub.map((p) => ({ target: p.as.addr, data: SEL_BALANCEOF + pad(p.a) }))) }, "latest"] });
    }
    for (const { k, v } of await rpcBatch(reqs)) {
      if (!v || v === "0x") continue;
      const sub = pairs.slice(k, k + PER_MULTICALL);
      const vals = decodeMulticall(v, sub.length);
      sub.forEach((p, ix) => {
        const x = vals[ix];
        if (x && x > 0n) { const m = bal.get(p.a) || {}; m[p.as.sym] = x.toString(); bal.set(p.a, m); }
      });
    }
    process.stderr.write(`\r  balances ${Math.min(i + PER_MULTICALL * 25, pairs.length)}/${pairs.length}   `);
    await sleep(PACE);
  }
  process.stderr.write("\n");

  fs.writeFileSync(new URL("./holders-balances.json", import.meta.url), JSON.stringify({
    at: new Date().toISOString(), window: raw.window, head: raw.head, prices,
    addresses: addrs.length, priced_subset: poor.length,
    rows: [...bal.entries()].map(([a, m]) => ({ a, eth: (eth.get(a) ?? 0n).toString(), bal: m })),
  }, null, 1));
  console.error("wrote script/recon/holders-balances.json");
})();
