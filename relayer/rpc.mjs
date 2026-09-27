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

async function batchOne(reqs, { timeoutMs = 30000 } = {}) {
  const body = reqs.map((r) => ({ jsonrpc: "2.0", id: ++id, method: r.method, params: r.params }));
  for (let i = 0; i < RPCS.length; i++) {
    try {
      const r = await fetch(RPCS[i], {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs),
      });
      if (r.status === 429) continue;
      const j = await r.json();
      if (!Array.isArray(j)) continue;
      const m = new Map(j.map((x) => [x.id, x]));
      healthy[i] = true;
      return body.map((b) => { const z = m.get(b.id); return z && !z.error ? z.result : null; });
    } catch { healthy[i] = false; }
  }
  return reqs.map(() => null);
}
