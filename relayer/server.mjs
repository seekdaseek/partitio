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
import { prepareOrder } from "./prepare.mjs";
import { createSender, assertLocalAnvil } from "./sender.mjs";
import { parseSignature, recoverTypedDataAddress, getAddress } from "viem";
import { ORDER_TYPES, domainFor, normalizeOrder } from "./order.mjs";

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
let sender = null;
// Broadcasting needs THREE things: the key file, the float, and this switch set to 1 in the PM2
// environment. The switch exists so that putting the key on the box and turning sending on are
// two separate, deliberate acts.
const SEND_ENABLED = process.env.PARTITIO_SEND === "1";
async function loadHotKey() {
  let j;
  try { j = JSON.parse(fs.readFileSync(CFG.HOT_KEY_FILE, "utf8")); } catch { hotAddress = null; return; }
  hotAddress = (j.address || j.data?.[0]?.address) ?? null;
  const pk = j.private_key || j.privateKey || j.data?.[0]?.private_key || null;
  if (!pk || !SEND_ENABLED) return;
  const anvil = Boolean(process.env.PARTITIO_RPC_OVERRIDE);
  if (anvil) await assertLocalAnvil(process.env.PARTITIO_RPC_OVERRIDE);
  sender = createSender({ privateKey: pk, chainId: CFG.CHAIN_ID, anvil });
  if (sender.address.toLowerCase() !== String(hotAddress).toLowerCase()) {
    throw new Error("hot key file: the address field does not match the key");
  }
}
await loadHotKey();

// ---- low-float alarm: Telegram, token read from liqbot's env file on the box, never logged ----
const ALARM_WEI = BigInt(process.env.PARTITIO_FLOAT_ALARM_WEI || "60000000000000");   // 0.00006 ETH
let lastAlarm = 0;
function tgCreds() {
  try {
    const env = Object.fromEntries(fs.readFileSync("/opt/liqbot/.env", "utf8").split("\n")
      .map((l) => l.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/)).filter(Boolean).map((m) => [m[1], m[2].replace(/^["']|["']$/g, "")]));
    return env.TG_BOT_TOKEN && env.TG_ALERT_CHAT ? { token: env.TG_BOT_TOKEN, chat: env.TG_ALERT_CHAT } : null;
  } catch { return null; }
}
async function floatAlarm() {
  if (!hotAddress || floatWei === 0n && !SEND_ENABLED) return;
  if (floatWei >= ALARM_WEI || Date.now() - lastAlarm < 6 * 3600_000) return;
  const c = tgCreds();
  if (!c) return;
  lastAlarm = Date.now();
  const fills = Number(floatWei / 9_000_000_000_000n);   // ~414k gas at 0.02 gwei, with headroom
  const text = `partitio relayer float low: ${(Number(floatWei) / 1e18).toFixed(6)} ETH, about ${fills} fills left. ` +
    `Below ${Number(CFG.FLOAT_MIN_WEI) / 1e18} ETH it goes quotes-only. Relayer ${hotAddress}`;
  try {
    await fetch(`https://api.telegram.org/bot${c.token}/sendMessage`, { method: "POST",
      headers: { "content-type": "application/json" }, body: JSON.stringify({ chat_id: c.chat, text }),
      signal: AbortSignal.timeout(10000) });
    log("float alarm sent");
  } catch (e) { log("float alarm failed:", String(e.message).slice(0, 80)); }
}

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
  if (!SEND_ENABLED || !sender) return { trading: false, reason: "sending-switched-off" };
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
  const rel = urlPath === "/" ? "/partitio-index.html" : urlPath;
  const file = path.join(HERE, "public", path.normalize(rel).replace(/^(\.\.[/\\])+/, ""));
  if (!file.startsWith(path.join(HERE, "public"))) { json(res, 403, { error: "forbidden" }); return true; }
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) return false;
  res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream" });
  res.end(fs.readFileSync(file));
  return true;
}

// ---- development wallet: ONLY against a local anvil ----
// Lets the real page be driven end to end on the fork. It exists only when PARTITIO_RPC_OVERRIDE is
// set AND assertLocalAnvil passed at startup (loopback URL, node reports anvil); on any other
// configuration the route is never registered and the page falls back to window.ethereum.
let devWallet = null;
if (process.env.PARTITIO_RPC_OVERRIDE) {
  await assertLocalAnvil(process.env.PARTITIO_RPC_OVERRIDE);
  const { privateKeyToAccount } = await import("viem/accounts");
  // anvil development account #2 - public, worthless anywhere but a local fork
  devWallet = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
}
function asTyped(json) {
  const t = typeof json === "string" ? JSON.parse(json) : json;
  const types = { ...t.types }; delete types.EIP712Domain;
  // a wallet accepts decimal strings for integers; viem wants bigints - convert by declared type
  const conv = (type, v) => {
    if (types[type]) return Object.fromEntries(types[type].map((f) => [f.name, conv(f.type, v[f.name])]));
    return /^u?int\d*$/.test(type) ? BigInt(v) : v;
  };
  return { domain: t.domain, types, primaryType: t.primaryType, message: conv(t.primaryType, t.message) };
}
async function devRpc({ method, params }) {
  switch (method) {
    case "eth_accounts": case "eth_requestAccounts": return [devWallet.address];
    case "eth_chainId": return "0x" + CFG.CHAIN_ID.toString(16);
    case "wallet_switchEthereumChain": case "wallet_addEthereumChain": return null;
    case "eth_signTypedData_v4": return devWallet.signTypedData(asTyped(params[1]));
    case "eth_call": case "eth_getBalance": case "eth_blockNumber": return call(method, params);
    default: throw new Error(`dev wallet: ${method} not supported`);
  }
}
const TOKENS_JSON = fs.readFileSync(path.join(HERE, "tokens.json"), "utf8");

// ---- orders: from two browser signatures to a fill ----
const today = () => new Date().toISOString().slice(0, 10);
const insOrder = db.prepare(`INSERT OR IGNORE INTO orders
  (at,order_hash,owner,is_team,direction,ticker,amount_in,notional_usd,chosen,amount_out,fee_usdg,tx_hash,status,err)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
const bumpDaily = db.prepare(`INSERT INTO daily_use (owner,day,notional,fills) VALUES (?,?,?,1)
  ON CONFLICT(owner,day) DO UPDATE SET notional = notional + excluded.notional, fills = fills + 1`);
const getDaily = db.prepare("SELECT notional, fills FROM daily_use WHERE owner = ? AND day = ?");

async function placeOrder(body) {
  const { order, orderSignature, fundsSignature, ticker, direction } = body || {};
  if (!order || !orderSignature || !fundsSignature || !ticker || !direction) {
    return { code: 400, out: { error: "order, orderSignature, fundsSignature, ticker and direction are required" } };
  }
  let o, f;
  try { o = parseSignature(orderSignature); f = parseSignature(fundsSignature); }
  catch { return { code: 400, out: { error: "malformed signature" } }; }
  const v = (p) => Number(p.v ?? BigInt(p.yParity + 27));

  // the per-wallet caps key on the RECOVERED signer, not on a field the client wrote
  let signer;
  try {
    signer = await recoverTypedDataAddress({ domain: domainFor(CFG.GASLESS_ENTRY, CFG.CHAIN_ID), types: ORDER_TYPES,
      primaryType: "Order", message: normalizeOrder(order), signature: orderSignature });
  } catch { return { code: 400, out: { error: "bad order signature" } }; }
  const owner = getAddress(signer).toLowerCase();
  const isTeam = CFG.TEAM_ADDRESSES.has(owner) ? 1 : 0;
  const d = getDaily.get(owner, today()) ?? { notional: 0, fills: 0 };
  const notionalUsd = direction === "buy" ? Number(BigInt(order.amountIn)) / 1e6 : null;
  if (d.fills >= CFG.MAX_DAILY_FILLS_PER_ADDRESS) return { code: 429, out: { error: "daily fill cap reached", cap: CFG.MAX_DAILY_FILLS_PER_ADDRESS } };
  if (notionalUsd != null && d.notional + notionalUsd > CFG.MAX_DAILY_USD_PER_ADDRESS) {
    return { code: 429, out: { error: "daily size cap reached", capUsd: CFG.MAX_DAILY_USD_PER_ADDRESS } };
  }

  const auth = { signature: orderSignature, v: v(o), r: o.r, s: o.s, pv: v(f), pr: f.r, ps: f.s,
    validAfter: 0, validBefore: order.deadline };
  const req = { order, auth, fee: order.maxFeeUsdg, slippageBps: body.slippageBps, ticker, direction };
  const { code, out } = await handleOrder(req, { send: sender });

  const status = out.sent ? (out.ok ? "confirmed" : "failed") : (code === 200 ? "simulated" : "refused");
  insOrder.run(new Date().toISOString(), out.orderHash ?? "unknown-" + Date.now(), owner, isTeam, direction, ticker,
    String(order.amountIn), notionalUsd, "partitio", null, String(order.maxFeeUsdg), out.txHash ?? null, status,
    out.sent ? null : (out.reason || out.error || null));
  if (out.sent && out.ok) {
    bumpDaily.run(owner, today(), notionalUsd ?? 0);
    refreshFloat().then(floatAlarm).catch(() => {});
  }
  log(`order ${String(out.orderHash).slice(0, 10)} ${direction} ${ticker} owner ${owner.slice(0, 8)} -> ${status}${out.txHash ? " " + out.txHash : ""}`);
  return { code, out: { ...out, isTeam: Boolean(isTeam) } };
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "?";
  const h = ipHash(ip);
  try {
    if (u.pathname === "/api/health") {
      return json(res, 200, {
        ok: true, mode: mode(), relayer: hotAddress, sending: Boolean(SEND_ENABLED && sender),
        floatEth: Number(floatWei) / 1e18, floatMinEth: Number(CFG.FLOAT_MIN_WEI) / 1e18,
        rpcs: rpcStatus(), chainId: CFG.CHAIN_ID,
        contracts: { routerV2: CFG.ROUTER_V2, gaslessEntry: CFG.GASLESS_ENTRY },
        caps: { maxTradeUsd: CFG.MAX_TRADE_USD, maxDailyUsd: CFG.MAX_DAILY_USD_PER_ADDRESS,
                maxDailyFills: CFG.MAX_DAILY_FILLS_PER_ADDRESS },
      });
    }
    if (u.pathname === "/api/tickers") return json(res, 200, { tickers: tickers(), hidden: [...HIDDEN] });
    if (u.pathname === "/partitio-tokens.json") {
      res.writeHead(200, { "content-type": "application/json", "cache-control": "max-age=300" });
      return res.end(TOKENS_JSON);
    }
    if (u.pathname === "/__dev/wallet" && req.method === "POST") {
      if (!devWallet) return json(res, 404, { error: "not found" });
      const body = await readBody(req);
      try { return json(res, 200, { result: await devRpc(body) }); }
      catch (e) { return json(res, 200, { error: String(e.message || e) }); }
    }
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
    if (u.pathname === "/api/prepare" && req.method === "POST") {
      if (!rateOk(h)) return json(res, 429, { error: "rate limited", perMinute: CFG.QUOTE_RATE_PER_MIN });
      const body = await readBody(req);
      const { code, out } = await prepareOrder(body);
      return json(res, code, { ...out, mode: mode() });
    }
    if (u.pathname === "/api/order" && req.method === "POST") {
      if (!rateOk(h)) return json(res, 429, { error: "rate limited", scope: "ip", perMinute: CFG.QUOTE_RATE_PER_MIN });
      const m = mode();
      if (!m.trading) return json(res, 503, { error: "trading paused", reason: m.reason, quotesStillWork: true });
      const body = await readBody(req);
      const r = await placeOrder(body);
      return json(res, r.code, r.out);
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
    return json(res, 404, { error: "not found", routes: ["/api/health", "/api/tickers", "/api/quote", "/api/prepare", "/api/order", "/api/order/simulate", "/api/stats"] });
  } catch (e) {
    log("request failed:", e.message);
    return json(res, 500, { error: String(e.message || e) });
  }
});

await refreshFloat();
setInterval(() => refreshFloat().then(floatAlarm).catch(() => {}), 60000);
server.listen(CFG.PORT, "127.0.0.1", () =>
  log(`relayer on 127.0.0.1:${CFG.PORT} · mode ${JSON.stringify(mode())} · relayer key ${hotAddress ?? "none"}`));
