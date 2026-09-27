// RPC with automatic fallback. The QuickNode trial expires ~Oct 24 and the results date is
// Oct 25, so "it stopped working on the day that mattered" is a foreseeable failure, not an
// accident: every call walks the list until one answers.
import { RPCS } from "./config.mjs";

let id = 0;
let healthy = new Array(RPCS.length).fill(true);

export function rpcStatus() {
  return RPCS.map((u, i) => ({
    // never expose the key-bearing URL
    name: i === 0 && /quiknode|quicknode/i.test(u) ? "quicknode" : new URL(u).host,
    healthy: healthy[i],
  }));
}

export async function call(method, params, { timeoutMs = 20000 } = {}) {
  let lastErr = null;
  for (let i = 0; i < RPCS.length; i++) {
    try {
      const r = await fetch(RPCS[i], {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (r.status === 429) { lastErr = new Error("429"); continue; }
      const j = await r.json();
      if (j.error) {
        // Keep the node's revert payload. Throwing only the message dropped `error.data`, so every
        // simulated revert reached explainRevert as "unknown" - found on the fork, where a resubmit
        // of a filled order was refused correctly but could not say why.
        lastErr = new Error(j.error.message);
        lastErr.code = j.error.code;
        lastErr.data = j.error.data;
        if (/limit|quota|credit/i.test(j.error.message)) continue;
        throw lastErr;
      }
      healthy[i] = true;
      return j.result;
    } catch (e) {
      healthy[i] = false;
      lastErr = e;
    }
  }
  throw lastErr ?? new Error("no rpc answered");
}

// Chunked, because the endpoints disagree about batch size and a silently-truncated batch is
// worse than a slow one: publicnode accepts 30, the canonical RPC tightens under load, and a
// partial result makes a split look thin rather than failing loudly.
const MAX_BATCH = 25;

export async function batch(reqs, opts = {}) {
  if (reqs.length <= MAX_BATCH) return batchOne(reqs, opts);
  const out = [];
  for (let i = 0; i < reqs.length; i += MAX_BATCH) {
    out.push(...(await batchOne(reqs.slice(i, i + MAX_BATCH), opts)));
  }
  return out;
}

// A rate limit is not an answer. QuickNode counts every call in a batch against 15/s and returns
// HTTP 200 with per-item "request limit reached" errors; treating those as null made a rate-limited
// batch read as a thin market - the $50 AAPL quote came back as 0.018 AAPL through one venue with no
// best single pool at all. Limited items now retry on the next endpoint; a genuine revert (a pool
// that cannot fill the size) stays null, because that IS the answer.
const isLimit = (err) => /limit|rate|quota|credit|too many|exceeded|capacity/i.test(String(err?.message || ""));

// Batches go first to endpoints that serve batches (publicnode: 30 per batch, measured), and to the
// per-call-metered archive endpoint last. Single calls keep the configured order.
function batchOrder() {
  const idx = RPCS.map((_, i) => i);
  if (RPCS.length < 2) return idx;
  const metered = (u) => /quiknode|quicknode/i.test(u);
  return [...idx.filter((i) => !metered(RPCS[i])), ...idx.filter((i) => metered(RPCS[i]))];
}

async function batchOne(reqs, { timeoutMs = 30000 } = {}) {
  const body = reqs.map((r) => ({ jsonrpc: "2.0", id: ++id, method: r.method, params: r.params }));
  const results = new Array(reqs.length).fill(undefined);   // undefined = not answered yet
  let pending = body.map((_, k) => k);
  for (const i of batchOrder()) {
    if (!pending.length) break;
    try {
      const r = await fetch(RPCS[i], {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify(pending.map((k) => body[k])), signal: AbortSignal.timeout(timeoutMs),
      });
      if (r.status === 429) continue;
      const j = await r.json();
      if (!Array.isArray(j)) continue;
      const m = new Map(j.map((x) => [x.id, x]));
      healthy[i] = true;
      const still = [];
      for (const k of pending) {
        const z = m.get(body[k].id);
        if (!z || (z.error && isLimit(z.error))) { still.push(k); continue; }
        results[k] = z.error ? null : z.result;
      }
      pending = still;
    } catch { healthy[i] = false; }
  }
  return results.map((x) => (x === undefined ? null : x));
}
