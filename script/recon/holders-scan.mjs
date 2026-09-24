// G2: who holds Robinhood Chain stock tokens, and can they afford to move them?
//
// SCOPE, stated up front: this scans a BOUNDED recent window of Transfer logs, not all history.
// USDG alone exceeds the RPC's 10,000-result cap inside 10,000 blocks, and the chain is 71M
// blocks deep, so a full-history holder set is not reachable through this RPC in the time
// available. The chain's Blockscout explorer sits behind a Cloudflare challenge and was not
// circumvented.
//
// The resulting count is therefore a LOWER BOUND, and the bias runs in the conservative
// direction: wallets that transferred recently are MORE likely to hold ETH than dormant ones,
// so the true zero-ETH population is at least this large.
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const T_XFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const CFG = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url)));
const WINDOW = Number(process.env.SCAN_WINDOW || 1_000_000);
const PAGE = Number(process.env.SCAN_PAGE || 100_000);
const PACE = 1200;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pad = (h) => String(h).replace(/^0x/, "").toLowerCase().padStart(64, "0");
let id = 0;

async function rpc(method, params, retries = 5) {
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(2000 * 2 ** (i - 1));
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }), signal: AbortSignal.timeout(90000) })
      .catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!j) continue;
    if (j.error) {
      if (/Too Many Requests|timed out/i.test(j.error.message || "")) continue;
      return { err: j.error.message };
    }
    return { ok: j.result };
  }
  return { err: "rate-limited after retries" };
}

async function rpcBatch(calls, retries = 5) {
  const body = calls.map((c) => ({ jsonrpc: "2.0", id: ++id, method: c.method, params: c.params, _k: c.k }));
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
  return calls.map((c) => ({ k: c.k, v: null }));
}

(async () => {
  const head = parseInt((await rpc("eth_blockNumber", [])).ok, 16);
  const from = head - WINDOW;
  const at = new Date().toISOString();
  console.error(`# holder scan · blocks ${from}..${head} (${WINDOW}) · page ${PAGE} · ${at}`);

  const tickers = Object.keys(CFG.tokens);
  const holders = new Set();
  const perToken = {};
  let pages = 0, failedPages = 0, logs = 0;

  for (const t of tickers) {
    const addr = CFG.tokens[t];
    let n = 0, seen = new Set();
    for (let b = from; b < head; b += PAGE) {
      const to = Math.min(b + PAGE - 1, head);
      const r = await rpc("eth_getLogs", [{ fromBlock: "0x" + b.toString(16), toBlock: "0x" + to.toString(16),
        address: addr, topics: [T_XFER] }]);
      pages++;
      if (r.err) { failedPages++; await sleep(PACE); continue; }
      n += r.ok.length; logs += r.ok.length;
      for (const l of r.ok) {
        // topics[1]=from topics[2]=to ; collect both, zero address excluded
        for (const ti of [1, 2]) {
          const a = "0x" + (l.topics[ti] || "").slice(26);
          if (a.length === 42 && a !== "0x0000000000000000000000000000000000000000") { holders.add(a); seen.add(a); }
        }
      }
      await sleep(PACE);
    }
    perToken[t] = { transfers: n, addresses: seen.size };
    console.error(`  ${t.padEnd(6)} transfers ${String(n).padStart(6)}  addrs ${String(seen.size).padStart(5)}  (running unique ${holders.size})`);
  }

  console.error(`\npages ${pages} (${failedPages} failed) · logs ${logs} · unique addresses ${holders.size}`);
  fs.writeFileSync(new URL("./holders-raw.json", import.meta.url),
    JSON.stringify({ at, head, from, window: WINDOW, perToken, pages, failedPages, logs,
      addresses: [...holders] }, null, 1));
  console.error("wrote script/recon/holders-raw.json");
})();
