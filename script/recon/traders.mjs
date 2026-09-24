// G2(e): unique tx.from of swap transactions.
//
// The Swap event's `sender` and `recipient` topics are routers and aggregator executors, not
// people. The only way to count traders is to pull each swap's transaction and read its `from`.
// An earlier pass counted recipients and reported 630 — that was a count of router destinations.
import fs from "node:fs";

// THREE RPCs, by capability:
//   canonical  - the only one that serves eth_getLogs over a useful range
//   QuickNode  - free "discover" plan caps eth_getLogs at a FIVE BLOCK range, so it is used only
//                for eth_getTransactionByHash, which it serves fine at 30-item batches
//   publicnode - bulk state reads (not needed here)
const QN = fs.readFileSync(process.env.HOME + "/.config/partitio/qn_rpc", "utf8").trim();
const CANON = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const T_SWAP = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67";
const WINDOW = Number(process.env.SCAN_WINDOW || 1_000_000);
const POOLS = {
  "AAPL/USDG f500": "0xaae0d815ee56e4092a5e5c2911e676fea50b2d6d",
  "AAPL/USDG f3000": "0x783c9bbb765047cfdd2b84b92b2ca9f11d34b7ed",
  "AAPL/WETH f500": "0x8bb3514e2204e1cdf3ac149efee7ff04d91b719f",
  "NVDA/WETH f500": "0x62ab521f71431f78ac374cdbadc6cda3c8916b6c",
  "SPY/USDG f500": "0xa7bb1ac63bbab0c44316e6c8c455213441689167",
  "SPY/WETH f500": "0xddcbba3666f578e3f09516f21ff85bfee859ab5e",
  "WETH/USDG f100": "0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca",
  "up-v3 AAPL/USDG": "0x19d55aba3e5d2c389b7011c634725136dfdcae33",
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let id = 0, reqs = 0;

async function rpc(method, params, retries = 4, url = QN) {
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1200 * 2 ** (i - 1));
    if (url === QN) reqs++;
    const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }), signal: AbortSignal.timeout(60000) }).catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!j) continue;
    if (j.error) {
      if (/Too Many Requests|timed out/i.test(j.error.message || "")) continue;
      return { err: j.error.message };
    }
    return { ok: j.result };
  }
  return { err: "retries exhausted" };
}
async function batch(items, make, retries = 4) {
  const body = items.map((x) => ({ jsonrpc: "2.0", id: ++id, ...make(x), _k: x }));
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1200 * 2 ** (i - 1));
    reqs++;
    const r = await fetch(QN, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body.map(({ _k, ...v }) => v)), signal: AbortSignal.timeout(60000) }).catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!Array.isArray(j)) continue;
    const m = new Map(j.map((x) => [x.id, x]));
    return body.map((b) => { const z = m.get(b.id); return { k: b._k, v: z && !z.error ? z.result : null }; });
  }
  return items.map((x) => ({ k: x, v: null }));
}

(async () => {
  const head = parseInt((await rpc("eth_blockNumber", [], 4, CANON)).ok, 16);
  const from = head - WINDOW;
  console.log(`window ${from}..${head} (${WINDOW} blocks ~ ${(WINDOW * 0.1008 / 86400).toFixed(2)} days)`);

  const txs = new Set();
  const senders = new Set(), recips = new Set();
  let swaps = 0, failedPages = 0;
  for (const [name, addr] of Object.entries(POOLS)) {
    let n = 0, fp = 0;
    for (let b = from; b < head; b += 200000) {
      const to = Math.min(b + 199999, head);
      const r = await rpc("eth_getLogs", [{ fromBlock: "0x" + b.toString(16), toBlock: "0x" + to.toString(16),
        address: addr, topics: [T_SWAP] }], 4, CANON);
      if (r.err) { fp++; failedPages++; if (fp === 1) console.log(`    (${name} page error: ${String(r.err).slice(0, 70)})`); await sleep(600); continue; }
      n += r.ok.length;
      for (const l of r.ok) {
        txs.add(l.transactionHash);
        senders.add("0x" + l.topics[1].slice(26));
        recips.add("0x" + l.topics[2].slice(26));
      }
      await sleep(250);
    }
    swaps += n;
    console.log(`  ${name.padEnd(18)} swaps ${String(n).padStart(6)}  failed pages ${fp}`);
  }
  console.log(`\nswaps ${swaps} · unique txs ${txs.size} · failed pages ${failedPages}`);

  // the actual answer: tx.from
  const list = [...txs];
  const froms = new Map();
  let unread = 0;
  for (let i = 0; i < list.length; i += 30) {
    for (const { v } of await batch(list.slice(i, i + 30), (h) => ({ method: "eth_getTransactionByHash", params: [h] }))) {
      if (!v || !v.from) { unread++; continue; }
      const f = v.from.toLowerCase();
      froms.set(f, (froms.get(f) || 0) + 1);
    }
    if (i % 3000 === 0) process.stderr.write(`\r  tx ${i}/${list.length}   `);
    await sleep(120);
  }
  process.stderr.write(`\r  tx ${list.length}/${list.length}   \n`);

  const top = [...froms.entries()].sort((a, b) => b[1] - a[1]);
  console.log(`\nunique tx.from (real traders) : ${froms.size}`);
  console.log(`unique Swap senders (routers) : ${senders.size}`);
  console.log(`unique Swap recipients        : ${recips.size}`);
  console.log(`transactions unreadable       : ${unread}`);
  console.log(`\ntop 8 senders by swap-tx count:`);
  for (const [a, c] of top.slice(0, 8)) console.log(`  ${a}  ${c}`);
  const oneShot = top.filter(([, c]) => c === 1).length;
  console.log(`\naddresses with exactly one swap tx: ${oneShot} (${(100 * oneShot / froms.size).toFixed(1)}%)`);
  console.log(`quicknode requests used: ${reqs}`);

  fs.writeFileSync(new URL("./traders.json", import.meta.url), JSON.stringify({
    at: new Date().toISOString(), window: WINDOW, head, swaps, uniqueTxs: txs.size,
    uniqueFrom: froms.size, uniqueSenders: senders.size, uniqueRecipients: recips.size,
    failedPages, unread, top: top.slice(0, 50).map(([a, c]) => ({ a, c })),
  }, null, 1));
  console.log("wrote script/recon/traders.json");
})();
