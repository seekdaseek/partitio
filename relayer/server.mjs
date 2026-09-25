// partitio relayer. Serves the web app from the SAME ORIGIN as the API, so there is no CORS
// surface and no second hostname to keep alive.
//
// Degradation, not downtime: if the ETH float runs dry, or the contracts are not deployed yet,
// quotes keep working and the app shows a banner. It never returns 5xx for a condition we already
// know about.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { DatabaseSync } from "node:sqlite";

import * as CFG from "./config.mjs";
import { call, rpcStatus } from "./rpc.mjs";
import { onChainQuote, tickers, HIDDEN } from "./quote.mjs";
import { allAggregators } from "./aggregators.mjs";
import { handleOrder } from "./submit.mjs";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const log = (...a) => console.log(new Date().toISOString(), ...a);

const db = new DatabaseSync(CFG.DB_PATH);
db.exec(fs.readFileSync(path.join(HERE, "schema.sql"), "utf8"));
const insQuote = db.prepare(`INSERT INTO quote
  (at,ip_hash,direction,ticker,amount_in,best_single,partitio,kyber,kyber_status,lifi,lifi_status,
   zerox,zerox_status,chosen,chosen_out,oracle_px,oracle_dev_bps,fee_usdg,ms)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);

// ---- hot key: read from a 0600 file generated ON the VPS, never printed ----
let hotAddress = null;
function loadHotAddress() {
  try {
    const j = JSON.parse(fs.readFileSync(CFG.HOT_KEY_FILE, "utf8"));
    hotAddress = (j.address || j.data?.[0]?.address) ?? null;
  } catch { hotAddress = null; }
  return hotAddress;
}
loadHotAddress();

let floatWei = 0n;
async function refreshFloat() {
  if (!hotAddress) return;
  try { floatWei = BigInt(await call("eth_getBalance", [hotAddress, "latest"])); }
  catch { /* keep the last reading rather than pretending it is zero */ }
}

function mode() {
  if (!CFG.GASLESS_ENTRY || !CFG.ROUTER_V2) return { trading: false, reason: "contracts-not-deployed" };
  if (!hotAddress) return { trading: false, reason: "no-relayer-key" };
  if (floatWei < CFG.FLOAT_MIN_WEI) return { trading: false, reason: "float-low" };
  return { trading: true, reason: null };
}

// ---- rate limiting, per hashed IP ----
const hits = new Map();
const ipHash = (ip) => crypto.createHash("sha256").update(CFG.IP_SALT + "|" + ip).digest("hex").slice(0, 16);
function rateOk(h) {
  const now = Date.now();
  const w = hits.get(h)?.filter((t) => now - t < 60000) ?? [];
  if (w.length >= CFG.QUOTE_RATE_PER_MIN) { hits.set(h, w); return false; }
  w.push(now); hits.set(h, w);
  return true;
}

const json = (res, code, obj) => {
  res.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  res.end(JSON.stringify(obj, null, 1));
};

async function readBody(req, limit = 64 * 1024) {
  const chunks = []; let n = 0;
  for await (const c of req) { n += c.length; if (n > limit) throw new Error("body too large"); chunks.push(c); }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
}

// ---- quote ----
async function handleQuote(body, h) {
  const t0 = Date.now();
  const { ticker, direction, amountIn } = body;
  if (!ticker || !["buy", "sell"].includes(direction) || !amountIn) {
    return { code: 400, out: { error: "ticker, direction (buy|sell) and amountIn are required" } };
  }
  if (HIDDEN.has(ticker)) {
    return { code: 400, out: { error: `${ticker} is not offered in v1`,
      reason: "priced by a Uniswap-pool-derived feed; a pool price cannot guard a trade that moves that pool" } };
  }
  let amt;
  try { amt = BigInt(amountIn); } catch { return { code: 400, out: { error: "amountIn must be an integer string" } }; }
  if (amt <= 0n) return { code: 400, out: { error: "amountIn must be positive" } };

  const onChain = await onChainQuote(ticker, direction, amt);
  const tokenIn = direction === "sell" ? onChainTokenOf(ticker) : CFG.USDG;
  const tokenOut = direction === "sell" ? CFG.USDG : onChainTokenOf(ticker);
  const aggs = await allAggregators(tokenIn, tokenOut, amt.toString());

  // pick the winner on NET output
  const candidates = [
    { name: "partitio", out: BigInt(onChain.partitio) },
    ...(aggs.kyber.ok ? [{ name: "kyber", out: aggs.kyber.out }] : []),
    ...(aggs.lifi.ok ? [{ name: "lifi", out: aggs.lifi.out }] : []),
    ...(aggs.zerox.ok ? [{ name: "0x", out: aggs.zerox.out }] : []),
  ].filter((c) => c.out > 0n);
  candidates.sort((a, b) => (b.out > a.out ? 1 : b.out < a.out ? -1 : 0));
  const winner = candidates[0] ?? null;

  const best = onChain.bestSingle ? BigInt(onChain.bestSingle) : null;
  const gainVsSingleBps = best && best > 0n && winner
    ? Number(((winner.out - best) * 10000n) / best) : null;

  const out = {
    ...onChain,
    aggregators: {
      kyber: aggs.kyber.ok ? { out: aggs.kyber.out.toString(), families: aggs.kyber.families, rfqShare: aggs.kyber.rfqShare, ms: aggs.kyber.ms }
                           : { unavailable: aggs.kyber.cls, ms: aggs.kyber.ms },
      lifi: aggs.lifi.ok ? { out: aggs.lifi.out.toString(), families: aggs.lifi.families, ms: aggs.lifi.ms }
                         : { unavailable: aggs.lifi.cls, ms: aggs.lifi.ms },
      "0x": aggs.zerox.ok ? { out: aggs.zerox.out.toString(), families: aggs.zerox.families, ms: aggs.zerox.ms }
                          : { unavailable: aggs.zerox.cls, ms: aggs.zerox.ms },
    },
    chosen: winner?.name ?? null,
    chosenOut: winner?.out.toString() ?? null,
    gainVsBestSinglePoolBps: gainVsSingleBps,
    // A sell into a pool trading below Chainlink is refused BY THE CONTRACT, so say so here
    // rather than letting the user sign an order that can only revert. IONQ and RKLB sit
    // ~11.7% and ~6.3% below their feeds persistently (script/predeploy-bindings.mjs), and
    // that refusal is the guard working, not a fault.
    ...sellPauseFor(direction, onChain.oracleDevBps),
    mode: mode(),
    ms: Date.now() - t0,
  };

  insQuote.run(new Date().toISOString(), h, direction, ticker, amt.toString(),
    onChain.bestSingle, onChain.partitio,
    aggs.kyber.ok ? aggs.kyber.out.toString() : null, aggs.kyber.ok ? "ok" : aggs.kyber.cls,
    aggs.lifi.ok ? aggs.lifi.out.toString() : null, aggs.lifi.ok ? "ok" : aggs.lifi.cls,
    aggs.zerox.ok ? aggs.zerox.out.toString() : null, aggs.zerox.ok ? "ok" : aggs.zerox.cls,
    out.chosen, out.chosenOut, onChain.oracleOut, onChain.oracleDevBps, null, out.ms);

  return { code: 200, out };
}

/// The app's default band. A fill more than this below Chainlink will not clear the floor the
/// client signs, so the quote warns before a signature exists rather than after a revert.
const APP_BAND_BPS = 200;
const WARN_BPS = 200;

function sellPauseFor(direction, oracleDevBps) {
  if (oracleDevBps == null) return { oracleWarn: null, sellPaused: false };
  const belowBps = -oracleDevBps;                       // positive when the pool is under the feed
  const warn = belowBps >= WARN_BPS
    ? `on-chain price is ${(belowBps / 100).toFixed(1)}% below Chainlink`
    : null;
  if (direction !== "sell" || belowBps < APP_BAND_BPS) {
    return { oracleWarn: warn, sellPaused: false };
  }
  return {
    oracleWarn: warn,
    sellPaused: true,
    sellPausedReason:
      `sells paused: best on-chain price is ${(belowBps / 100).toFixed(1)}% below Chainlink, ` +
      `which is outside the ${APP_BAND_BPS / 100}% band the app signs`,
  };
}

let TOKENS = null;
function onChainTokenOf(ticker) {
  TOKENS ??= JSON.parse(fs.readFileSync(path.join(HERE, "tokens.json"), "utf8")).tokens;
  return TOKENS[ticker];
}

// ---- static ----
const MIME = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
               ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".json": "application/json",
               ".png": "image/png", ".webp": "image/webp", ".ico": "image/x-icon" };
function serveStatic(req, res, urlPath) {
  const rel = urlPath === "/" ? "/index.html" : urlPath;
  const file = path.join(HERE, "public", path.normalize(rel).replace(/^(\.\.[/\\])+/, ""));
  if (!file.startsWith(path.join(HERE, "public"))) { json(res, 403, { error: "forbidden" }); return true; }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) return false;
  res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream" });
  res.end(fs.readFileSync(file));
  return true;
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "?";
  const h = ipHash(ip);
  try {
    if (u.pathname === "/api/health") {
      return json(res, 200, {
        ok: true, mode: mode(), relayer: hotAddress,
        floatEth: Number(floatWei) / 1e18, floatMinEth: Number(CFG.FLOAT_MIN_WEI) / 1e18,
        rpcs: rpcStatus(), chainId: CFG.CHAIN_ID,
        contracts: { routerV2: CFG.ROUTER_V2, gaslessEntry: CFG.GASLESS_ENTRY },
        caps: { maxTradeUsd: CFG.MAX_TRADE_USD, maxDailyUsd: CFG.MAX_DAILY_USD_PER_ADDRESS,
                maxDailyFills: CFG.MAX_DAILY_FILLS_PER_ADDRESS },
      });
    }
    if (u.pathname === "/api/tickers") return json(res, 200, { tickers: tickers(), hidden: [...HIDDEN] });
    if (u.pathname === "/api/stats") {
      return json(res, 200, {
        quotes: db.prepare("SELECT COUNT(*) c FROM quote").get().c,
        orders: db.prepare("SELECT COUNT(*) c FROM orders").get().c,
        thirdPartyOrders: db.prepare("SELECT COUNT(*) c FROM orders WHERE is_team=0").get().c,
        distinctThirdPartyWallets: db.prepare("SELECT COUNT(DISTINCT owner) c FROM orders WHERE is_team=0").get().c,
      });
    }
    if (u.pathname === "/api/quote" && req.method === "POST") {
      if (!rateOk(h)) return json(res, 429, { error: "rate limited", perMinute: CFG.QUOTE_RATE_PER_MIN });
      const body = await readBody(req);
      const { code, out } = await handleQuote(body, h);
      return json(res, code, out);
    }
    if (u.pathname === "/api/order" && req.method === "POST") {
      if (!rateOk(h)) return json(res, 429, { error: "rate limited", scope: "ip", perMinute: CFG.QUOTE_RATE_PER_MIN });
      const m = mode();
      if (!m.trading) return json(res, 503, { error: "trading paused", reason: m.reason, quotesStillWork: true });
      const body = await readBody(req);
      // `send` is deliberately NOT passed: this build validates, re-quotes and SIMULATES, and
      // returns what would happen. Broadcasting is wired separately once the hot key is on the
      // box, so that no code path can send a transaction by accident before then.
      const { code, out } = await handleOrder(body, {});
      return json(res, code, out);
    }
    // Simulation without the trading gate, so the e2e matrix can exercise the refusals on a fork
    // before anything is deployed to mainnet.
    if (u.pathname === "/api/order/simulate" && req.method === "POST") {
      if (!rateOk(h)) return json(res, 429, { error: "rate limited", scope: "ip" });
      const body = await readBody(req);
      const { code, out } = await handleOrder(body, { entryAddress: body.entry ?? CFG.GASLESS_ENTRY });
      return json(res, code, out);
    }
    if (req.method === "GET" && serveStatic(req, res, u.pathname)) return;
    return json(res, 404, { error: "not found", routes: ["/api/health", "/api/tickers", "/api/quote", "/api/order", "/api/order/simulate", "/api/stats"] });
  } catch (e) {
    log("request failed:", e.message);
    return json(res, 500, { error: String(e.message || e) });
  }
});

await refreshFloat();
setInterval(refreshFloat, 60000);
server.listen(CFG.PORT, "127.0.0.1", () =>
  log(`relayer on 127.0.0.1:${CFG.PORT} · mode ${JSON.stringify(mode())} · relayer key ${hotAddress ?? "none"}`));
