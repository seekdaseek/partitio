// Aggregator quote sources. Every number returned here is NET of that provider's own fee, because
// comparing a gross quote against a net one silently picks the wrong route.
import fs from "node:fs";
import path from "node:path";
import { USDG } from "./config.mjs";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const readIf = (p) => { try { const v = fs.readFileSync(p, "utf8").trim(); return v || null; } catch { return null; } };
const ZEROX_KEY = readIf(path.join(HERE, "zerox_key")) || readIf(`${process.env.HOME}/.config/partitio/zerox_key`);

const KYBER = "https://aggregator-api.kyberswap.com/robinhood/api/v1/routes";
const CLIENT = "partitio";
const OFFCHAIN = ["pmm-19", "kipseli-prop"];

export async function kyber(tokenIn, tokenOut, amountIn, { timeoutMs = 6000 } = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(`${KYBER}?tokenIn=${tokenIn}&tokenOut=${tokenOut}&amountIn=${amountIn}`,
      { headers: { "x-client-id": CLIENT }, signal: AbortSignal.timeout(timeoutMs) });
    const j = await r.json().catch(() => null);
    if (j?.data?.routeSummary) {
      const rs = j.data.routeSummary;
      const fams = new Set();
      let offIn = 0n, totIn = 0n;
      for (const leg of rs.route || []) {
        for (const h of leg) fams.add(h.exchange);
        const f = leg[0]; if (!f) continue;
        const a = BigInt(f.swapAmount || 0); totIn += a;
        if (OFFCHAIN.includes(f.exchange)) offIn += a;
      }
      // Kyber's amountOut is already net of any extraFee it charges.
      return { ok: true, out: BigInt(rs.amountOut), families: [...fams].sort(),
               rfqShare: totIn > 0n ? Number((offIn * 10000n) / totIn) / 100 : 0, ms: Date.now() - t0 };
    }
    if (j?.code === 50301) return { ok: false, cls: "overloaded", http: r.status, ms: Date.now() - t0 };
    return { ok: false, cls: r.status === 429 ? "rate-limited" : "no-route", http: r.status,
             err: j?.message, ms: Date.now() - t0 };
  } catch (e) {
    return { ok: false, cls: "transport", err: String(e.message || e), ms: Date.now() - t0 };
  }
}

export async function lifi(tokenIn, tokenOut, amountIn, { timeoutMs = 8000 } = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch("https://li.quest/v1/advanced/routes", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ fromChainId: 4663, toChainId: 4663, fromTokenAddress: tokenIn,
                             toTokenAddress: tokenOut, fromAmount: amountIn }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const j = await r.json().catch(() => null);
    if (r.status === 429 || j?.code === 1005)
      return { ok: false, cls: "rate-limited", http: r.status, err: j?.message, ms: Date.now() - t0 };
    if (!j?.routes?.length)
      return { ok: false, cls: "no-route", http: r.status, err: j?.message, ms: Date.now() - t0 };
    let best = 0n; const tools = new Set();
    for (const rt of j.routes) {
      const a = BigInt(rt.toAmount || 0);
      if (a > best) best = a;
      for (const st of rt.steps || []) tools.add(st.toolDetails?.name || st.tool || "?");
    }
    return { ok: true, out: best, families: [...tools].sort(), ms: Date.now() - t0 };
  } catch (e) {
    return { ok: false, cls: "transport", err: String(e.message || e), ms: Date.now() - t0 };
  }
}

// 0x returned BUY/SELL_TOKEN_NOT_AUTHORIZED_FOR_TRADE for AAPL and SPY on chain 4663, from a
// Moldova IP and an EU IP, on a Standard key, while USDG<->WETH priced fine from both. It is kept
// wired and asked anyway — if that changes, the logs will show it the same day.
export async function zerox(tokenIn, tokenOut, amountIn, { timeoutMs = 6000 } = {}) {
  const t0 = Date.now();
  if (!ZEROX_KEY) return { ok: false, cls: "no-api-key", ms: 0 };
  try {
    const u = `https://api.0x.org/swap/allowance-holder/price?chainId=4663&sellToken=${tokenIn}`
            + `&buyToken=${tokenOut}&sellAmount=${amountIn}`;
    const r = await fetch(u, { headers: { "0x-api-key": ZEROX_KEY, "0x-version": "v2" },
                               signal: AbortSignal.timeout(timeoutMs) });
    const j = await r.json().catch(() => null);
    if (j?.buyAmount) {
      // 0x's Standard plan takes a swap fee inside the quote; buyAmount is what actually lands.
      const fills = (j.route?.fills || []).map((f) => f.source);
      return { ok: true, out: BigInt(j.buyAmount), families: [...new Set(fills)].sort(), ms: Date.now() - t0 };
    }
    const name = j?.name || "";
    const cls = /NOT_AUTHORIZED_FOR_TRADE/.test(name) ? "asset-class-refused"
              : r.status === 429 ? "rate-limited" : "no-route";
    return { ok: false, cls, http: r.status, err: name || j?.message, ms: Date.now() - t0 };
  } catch (e) {
    return { ok: false, cls: "transport", err: String(e.message || e), ms: Date.now() - t0 };
  }
}

/// Ask all three at once. A provider that does not answer inside its timeout is simply absent from
/// the comparison — it never blocks a quote.
export async function allAggregators(tokenIn, tokenOut, amountIn) {
  const [k, l, z] = await Promise.all([
    kyber(tokenIn, tokenOut, amountIn),
    lifi(tokenIn, tokenOut, amountIn),
    zerox(tokenIn, tokenOut, amountIn),
  ]);
  return { kyber: k, lifi: l, zerox: z };
}
