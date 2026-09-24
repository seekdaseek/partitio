// Venue discovery: harvest every (exchange, pool) Kyber will route through on 4663.
// ONE-TIME BACKFILL ONLY. Its purpose is to find hook poolIds, which cannot be derived
// (poolId needs the hook address as an input). After this, the registry is maintained by
// forward-watching PoolManager Initialize and each v3 factory's PoolCreated via eth_getLogs
// on the canonical RPC, which does serve logs in 20,000-block windows.
//
// Runs on the VPS: Kyber returns 503 to the Mac. Pure HTTP + eth_call, no repo imports.
// Nothing discovered here enters the registry until verify-venues.mjs proves it on-chain.
import fs from "node:fs";

const RPC = "https://rpc.mainnet.chain.robinhood.com";
const KYBER = "https://aggregator-api.kyberswap.com/robinhood/api/v1/routes";
const CLIENT_ID = "partitio";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const QUOTER_V2 = "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7";
const SIZES_USD = [1000, 10000, 100000, 500000];
const PACE_MS = 2600;
const MAX_RETRY = 3;

const CFG = JSON.parse(fs.readFileSync(process.argv[2] || "./tokens.json", "utf8"));
const TOKENS = CFG.tokens;

const pad = (h) => h.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let rpcId = 0;

async function ethCall(to, data) {
  const r = await fetch(RPC, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const j = await r.json();
  return j.error ? null : j.result;
}

// QuoterV2.quoteExactInputSingle((tokenIn,tokenOut,amountIn,fee,sqrtPriceLimitX96))
const SEL_QUOTE = "0xc6a5026a";
async function unitPrice(token) {
  for (const fee of [500, 3000, 10000, 100]) {
    const data = SEL_QUOTE + pad(token) + pad(USDG) + pad((10n ** 18n).toString(16)) + pad(fee.toString(16)) + pad("0");
    const r = await ethCall(QUOTER_V2, data);
    if (r && r !== "0x") {
      const out = BigInt("0x" + r.slice(2, 66));
      if (out > 0n) return { usd: Number(out) / 1e6, viaFee: fee };
    }
  }
  return null;
}

async function kyberRoute(tokenIn, amountIn) {
  const url = `${KYBER}?tokenIn=${tokenIn}&tokenOut=${USDG}&amountIn=${amountIn}`;
  for (let attempt = 0; attempt <= MAX_RETRY; attempt++) {
    if (attempt) await sleep(5000 * 2 ** (attempt - 1));
    try {
      const res = await fetch(url, { headers: { "x-client-id": CLIENT_ID }, signal: AbortSignal.timeout(25000) });
      const body = await res.json();
      if (body?.data?.routeSummary) return { ok: body, http: res.status, attempt };
      if (body?.code === 50301) continue;              // overloaded — retry
      return { err: body?.message || `code ${body?.code}`, http: res.status, attempt };
    } catch (e) {
      if (attempt === MAX_RETRY) return { err: String(e.message || e), attempt };
    }
  }
  return { err: "rate-limited after retries", attempt: MAX_RETRY };
}

(async () => {
  const startedAt = new Date().toISOString();
  const tickers = Object.keys(TOKENS);
  const prices = {};
  process.stderr.write(`# pricing ${tickers.length} tokens via QuoterV2\n`);
  for (const t of tickers) {
    prices[t] = await unitPrice(TOKENS[t]);
    process.stderr.write(`  ${t.padEnd(6)} ${prices[t] ? "$" + prices[t].usd.toFixed(2) : "NO QUOTE"}\n`);
  }

  const out = { startedAt, rpc: RPC, kyber: KYBER, clientId: CLIENT_ID, prices, routes: [] };
  const total = tickers.filter((t) => prices[t]).length * SIZES_USD.length;
  let n = 0, ok = 0, failed = 0;

  for (const t of tickers) {
    if (!prices[t]) { process.stderr.write(`${t}: skipped, no on-chain price\n`); continue; }
    for (const usd of SIZES_USD) {
      const amountIn = BigInt(Math.floor((usd / prices[t].usd) * 1e18)).toString();
      const at = new Date().toISOString();
      const r = await kyberRoute(TOKENS[t], amountIn);
      n++;
      if (r.ok) {
        ok++;
        const rs = r.ok.data.routeSummary;
        const hops = [];
        for (const leg of rs.route) for (const h of leg) {
          hops.push({ exchange: h.exchange, pool: h.pool, tokenIn: h.tokenIn, tokenOut: h.tokenOut, amountOut: h.amountOut });
        }
        out.routes.push({ ticker: t, usd, amountIn, at, amountOut: rs.amountOut, amountOutUsd: rs.amountOutUsd, hops });
        process.stderr.write(`[${n}/${total}] ${t} $${usd} -> ${rs.amountOut} (${hops.length} hops)\n`);
      } else {
        failed++;
        out.routes.push({ ticker: t, usd, amountIn, at, unmeasured: true, reason: r.err });
        process.stderr.write(`[${n}/${total}] ${t} $${usd} UNMEASURED: ${r.err}\n`);
      }
      await sleep(PACE_MS);
    }
  }
  out.finishedAt = new Date().toISOString();
  out.stats = { requested: n, ok, unmeasured: failed };
  fs.writeFileSync("harvest.json", JSON.stringify(out, null, 1));
  process.stderr.write(`\ndone: ${ok} ok, ${failed} unmeasured -> harvest.json\n`);
})();
