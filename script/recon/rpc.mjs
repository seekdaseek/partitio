// Minimal JSON-RPC helper for Robinhood Chain recon.
// Selectors are derived at runtime via `cast sig` so none is ever hardcoded from memory.
import { execFileSync } from "node:child_process";

export const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const CAST = `${process.env.HOME}/.foundry/bin/cast`;

const _sel = new Map();
export function sel(sig) {
  if (!_sel.has(sig)) {
    _sel.set(sig, execFileSync(CAST, ["sig", sig], { encoding: "utf8" }).trim());
  }
  return _sel.get(sig);
}

export const pad = (h) => h.replace(/^0x/, "").toLowerCase().padStart(64, "0");
export const addrArg = (a) => pad(a);
export const uintArg = (n) => pad(BigInt(n).toString(16));
export const boolArg = (b) => pad(b ? "1" : "0");

export const word = (data, i) => "0x" + data.replace(/^0x/, "").slice(i * 64, (i + 1) * 64);
export const toAddr = (w) => "0x" + w.replace(/^0x/, "").slice(24);
export const toBig = (w) => BigInt(w);
export function toInt24(w) {
  const v = BigInt(w) & ((1n << 24n) - 1n);
  return v >= 1n << 23n ? v - (1n << 24n) : v;
}

let id = 0;
export async function call(to, data, tag = "latest") {
  const body = { jsonrpc: "2.0", id: ++id, method: "eth_call", params: [{ to, data }, tag] };
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (j.error) return { err: j.error.message || JSON.stringify(j.error) };
  return { ok: j.result };
}

export async function pool(limit, items, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (true) {
        const i = next++;
        if (i >= items.length) return;
        out[i] = await fn(items[i], i);
      }
    })
  );
  return out;
}

export async function blockNumber() {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }),
  });
  return parseInt((await r.json()).result, 16);
}
