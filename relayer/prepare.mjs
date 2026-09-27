// Build an order and the exact typed data a browser wallet signs for it.
//
// The browser should not assemble an order: every field of it is money. It asks for one, signs the
// two payloads this returns with eth_signTypedData_v4, and posts the signatures back. The relayer
// then re-checks everything on /api/order - signature, a fresh quote, a simulation - so a tampered
// payload costs the tamperer a refusal, never the relayer gas.
//
// Two signatures, not one, and the UI must say so: the ORDER (what to trade, the floor, the fee
// cap) and the FUNDS - an EIP-3009 authorization for USDG on a buy, whose nonce IS the order hash
// so it can fund no other order, or an EIP-2612 permit for the stock on a sell.

import fs from "node:fs";
import { getAddress, keccak256, toHex } from "viem";
import * as CFG from "./config.mjs";
import { call } from "./rpc.mjs";
import { onChainQuote, usdgPerEth, HIDDEN } from "./quote.mjs";
import { ORDER_TYPES, domainFor, hashOrder, marketOrderDefaults, DEFAULT_SLIPPAGE_BPS, MAX_SLIPPAGE_BPS } from "./order.mjs";

// ---------------------------------------------------------------- the fee
//
// NOT a flat percentage. A flat 30 bps made partitio ~25 bps WORSE than sending the same pool swap
// yourself whenever the split did not beat the best single pool - which at $50 is most of the time.
// The fee is what the user would have paid anyway, plus a share of what we actually saved them:
//
//   fee = gas of the chosen route, in USDG      (what a direct swap of these legs costs; the
//                                                 ~280k gas of GaslessEntry's own overhead is on us)
//       + 20% of the improvement over the best single pool   (zero unless the split beats it)
//
// capped at 0.50% of the USDG side and at PARTITIO_MAX_FEE_USDG. The contract enforces 0.50% too,
// against the EXECUTED side - so on a sell, whose gross can land below the quote inside minOut,
// the cap is 0.50% x (1 - slippage) of the quote, or a fill that slipped would revert FeeAboveMax.
export const SAVINGS_SHARE_PCT = 20n;
export const APP_MAX_FEE_BPS = 50n;
export const MAX_FEE_USDG = BigInt(process.env.PARTITIO_MAX_FEE_USDG || 5_000_000);   // 5 USDG
/** The oracle band the app signs by default - measured to refuse 0.8% of $1k trades (docs/REVIEW-FIXES.md §11). */
export const APP_BAND_BPS = 200;
/** Display-only quotes may exceed the beta trade cap so the split can be watched at size; this is a sanity bound. */
export const PREVIEW_MAX_USD = 1_000_000;

const USDG_DOMAIN_FIELDS = { name: "Global Dollar", version: "1" };   // hashes to USDG.DOMAIN_SEPARATOR()

const EIP712_DOMAIN = [
  { name: "name", type: "string" }, { name: "version", type: "string" },
  { name: "chainId", type: "uint256" }, { name: "verifyingContract", type: "address" },
];
const RECEIVE = [
  { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
  { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" },
];
const PERMIT = [
  { name: "owner", type: "address" }, { name: "spender", type: "address" }, { name: "value", type: "uint256" },
  { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" },
];

const SEL = {
  nonces: "0x7ecebe00",          // nonces(address)
  eip712Domain: "0x84b0196e",    // eip712Domain()
  latestRoundData: "0xfeaf968c",
};
const word = (hex, i) => "0x" + hex.slice(2 + i * 64, 2 + (i + 1) * 64);

/** Decode EIP-5267 eip712Domain() - every stock token on 4663 implements it. */
async function stockDomain(token) {
  const r = await call("eth_call", [{ to: token, data: SEL.eip712Domain }, "latest"]);
  const readString = (offWord) => {
    const off = Number(BigInt(offWord)) * 2 + 2;
    const len = Number(BigInt("0x" + r.slice(off, off + 64)));
    return Buffer.from(r.slice(off + 64, off + 64 + len * 2), "hex").toString("utf8");
  };
  return {
    name: readString(word(r, 1)),
    version: readString(word(r, 2)),
    chainId: Number(BigInt(word(r, 3))),
    verifyingContract: getAddress("0x" + word(r, 4).slice(26)),
  };
}

const str = (o) => JSON.parse(JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v)));

/** US regular session in New York time - DST handled by the zone, holidays by feed age. */
export function usMarketOpen(date = new Date()) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York",
    weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(date).map((x) => [x.type, x.value]));
  if (parts.weekday === "Sat" || parts.weekday === "Sun") return false;
  const m = (Number(parts.hour) % 24) * 60 + Number(parts.minute);
  return m >= 9 * 60 + 30 && m < 16 * 60;
}

const TOKENS = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url), "utf8")).tokens;

function validate({ ticker, direction, amountIn }) {
  if (!ticker || !["buy", "sell"].includes(direction)) return "ticker and direction (buy|sell) are required";
  if (HIDDEN.has(ticker)) return `${ticker} is not offered in v1`;
  if (!TOKENS[ticker]) return `unknown ticker ${ticker}`;
  let amt;
  try { amt = BigInt(amountIn); } catch { return "amountIn must be an integer string in base units"; }
  if (amt <= 0n) return "amountIn must be positive";
  return null;
}

/**
 * Price a trade: route, fee, the best single pool it is compared with, and the Chainlink check.
 * Shared by the display-only quote and the signable order, so the two can never disagree.
 */
export async function priceTrade({ ticker, direction, amountIn, slippageBps = DEFAULT_SLIPPAGE_BPS }) {
  const amt = BigInt(amountIn);
  const sell = direction === "sell";
  const q = await onChainQuote(ticker, direction, amt);
  if (!q.legs?.length || !q.partitio || BigInt(q.partitio) === 0n) return { noRoute: true, q };

  const split = BigInt(q.partitio);
  const best = q.bestSingle ? BigInt(q.bestSingle) : 0n;
  // savings in USDG: exact on a sell; on a buy the extra stock is valued at the split's own price
  // no single pool quoting the full size is not "savings" - there is no alternative to beat
  const gainOut = best > 0n && split > best ? split - best : 0n;
  const savingsUsdg = sell ? gainOut : (gainOut * amt) / split;

  const [gpHex, perEth] = await Promise.all([call("eth_gasPrice", []), usdgPerEth()]);
  const gasPrice = BigInt(gpHex);
  const routeGas = BigInt(q.routeGas);
  const gasUsdg = (routeGas * gasPrice * perEth + 10n ** 18n - 1n) / 10n ** 18n;   // rounded up to the unit
  const shareUsdg = (savingsUsdg * SAVINGS_SHARE_PCT) / 100n;                      // rounded down
  const usdgSide = sell ? split : amt;
  const pctCap = sell
    ? (usdgSide * APP_MAX_FEE_BPS * (10_000n - BigInt(slippageBps))) / 100_000_000n
    : (usdgSide * APP_MAX_FEE_BPS) / 10_000n;
  let fee = gasUsdg + shareUsdg;
  let cappedBy = null;
  if (fee > pctCap) { fee = pctCap; cappedBy = "0.50% of the trade"; }
  if (fee > MAX_FEE_USDG) { fee = MAX_FEE_USDG; cappedBy = "the maximum fee"; }

  // buy: the fee comes off the input, so the route is scaled to what is left - concave pools make
  // the scaled output a slight UNDERestimate, which is the safe side for a floor built on it
  const spendable = sell ? amt : amt - fee;
  if (spendable <= 0n) return { tooSmall: true, q };
  const expectedOut = sell ? split - fee : (split * spendable) / amt;

  const head = await call("eth_getBlockByNumber", ["latest", false]);
  const now = Number(BigInt(head.timestamp));
  const feedAge = q.oracleUpdatedAt ? Math.max(0, now - Number(q.oracleUpdatedAt)) : null;
  const open = usMarketOpen(new Date(now * 1000));
  const dev = q.oracleDevBps;
  const band = dev == null ? "unknown" : -dev >= APP_BAND_BPS ? "refuse" : -dev >= 100 ? "warn" : "ok";

  const legTotal = q.legs.reduce((a, l) => a + BigInt(l.amountIn), 0n);
  return {
    q, amt, sell, fee, spendable, expectedOut, split, best, now, feedAge,
    display: {
      ticker, direction, amountIn: amt,
      notionalUsd: Number(sell ? split : amt) / 1e6,
      expectedOut,
      route: {
        legs: q.legs.map((l) => ({ name: l.name, kind: l.kind, family: l.family, amountIn: l.amountIn,
          amountOut: l.amountOut, pct: Number((BigInt(l.amountIn) * 10_000n) / legTotal) / 100 })),
        venues: q.legs.length,
      },
      bestSingle: { name: q.bestSingleName, out: best, gas: q.bestSingleGas },
      splitGainBps: best > 0n ? Number(((split - best) * 10_000n) / best) : null,
      savingsUsdg,
      fee: { total: fee, gasUsdg, gasUnits: routeGas, gasPriceWei: gasPrice, usdgPerEth: perEth,
             savingsShareUsdg: shareUsdg, savingsSharePct: Number(SAVINGS_SHARE_PCT), cappedBy,
             bps: Number((fee * 10_000n) / (usdgSide || 1n)) / 100 },
      oracle: { devBps: dev, band, updatedAt: q.oracleUpdatedAt, feedAgeSeconds: feedAge,
                marketOpen: open, stale: feedAge != null && feedAge > 5400, desc: q.oracleDesc },
      relayerPaysGas: true,
    },
  };
}

/** Display-only: no wallet, nothing signable, allowed above the beta trade cap. */
export async function previewQuote(body) {
  const bad = validate(body);
  if (bad) return { code: 400, out: { error: bad } };
  const p = await priceTrade(body);
  if (p.noRoute) return { code: 422, out: { error: "no route", reason: "no committed venue quoted this pair at this size" } };
  if (p.tooSmall) return { code: 400, out: { error: "amount too small to cover the network gas" } };
  if (p.display.notionalUsd > PREVIEW_MAX_USD) return { code: 400, out: { error: `preview is limited to $${PREVIEW_MAX_USD.toLocaleString()}` } };
  return { code: 200, out: str({ ...p.display, tradeable: p.display.notionalUsd <= CFG.MAX_TRADE_USD, capUsd: CFG.MAX_TRADE_USD }) };
}

/**
 * The signable order and its two typed-data payloads.
 * @returns {{code:number, out:object}}
 */
export async function prepareOrder({ ticker, direction, amountIn, owner, slippageBps = DEFAULT_SLIPPAGE_BPS },
  { entry = CFG.GASLESS_ENTRY, chainId = CFG.CHAIN_ID } = {}) {
  if (!entry) return { code: 503, out: { error: "trading paused", reason: "contracts-not-deployed" } };
  const bad = validate({ ticker, direction, amountIn });
  if (bad) return { code: 400, out: { error: bad } };
  let who;
  try { who = getAddress(owner); } catch { return { code: 400, out: { error: "owner must be an address" } }; }
  if (slippageBps > MAX_SLIPPAGE_BPS) return { code: 400, out: { error: `slippage above ${MAX_SLIPPAGE_BPS} bps` } };

  const p = await priceTrade({ ticker, direction, amountIn, slippageBps });
  if (p.noRoute) return { code: 422, out: { error: "no route", reason: "no committed venue quoted this pair at this size" } };
  if (p.tooSmall) return { code: 400, out: { error: "amount too small to cover the network gas" } };
  if (p.display.notionalUsd > CFG.MAX_TRADE_USD) {
    return { code: 400, out: { error: `beta: $${CFG.MAX_TRADE_USD} per trade`, capUsd: CFG.MAX_TRADE_USD, notionalUsd: p.display.notionalUsd } };
  }
  // Refuse before a signature exists, in the words the contract would have used after it
  if (p.display.oracle.band === "refuse") {
    return { code: 422, out: {
      error: p.sell ? "sells paused" : "buy refused",
      reason: `the best on-chain price is ${(-p.display.oracle.devBps / 100).toFixed(1)}% below Chainlink, outside the ${APP_BAND_BPS / 100}% band`,
      oracleDevBps: p.display.oracle.devBps } };
  }

  const stock = getAddress(TOKENS[ticker]);
  const d = marketOrderDefaults({ quotedNet: p.expectedOut, feedAgeAtQuote: p.feedAge ?? 0, nowSeconds: p.now, slippageBps });
  const order = {
    owner: who,
    tokenIn: p.sell ? stock : getAddress(CFG.USDG),
    amountIn: p.amt,
    tokenOut: p.sell ? getAddress(CFG.USDG) : stock,
    minOut: d.minOut,
    maxFeeUsdg: p.fee,
    deadline: d.deadline,
    salt: keccak256(toHex(`${who}-${Date.now()}-${Math.random()}`)),
    guard: { maxDevBps: BigInt(APP_BAND_BPS), maxFeedAge: d.maxFeedAge },
  };
  const orderHash = hashOrder(order, entry, chainId);
  const orderTyped = {
    domain: domainFor(entry, chainId),
    types: { EIP712Domain: EIP712_DOMAIN, ...ORDER_TYPES },
    primaryType: "Order",
    message: order,
  };

  let fundsTyped;
  if (!p.sell) {
    fundsTyped = {
      domain: { ...USDG_DOMAIN_FIELDS, chainId, verifyingContract: getAddress(CFG.USDG) },
      types: { EIP712Domain: EIP712_DOMAIN, ReceiveWithAuthorization: RECEIVE },
      primaryType: "ReceiveWithAuthorization",
      message: { from: who, to: getAddress(entry), value: p.amt, validAfter: 0n, validBefore: order.deadline, nonce: orderHash },
    };
  } else {
    const dom = await stockDomain(stock);
    const nonceHex = await call("eth_call", [{ to: stock, data: SEL.nonces + who.slice(2).toLowerCase().padStart(64, "0") }, "latest"]);
    fundsTyped = {
      domain: dom,
      types: { EIP712Domain: EIP712_DOMAIN, Permit: PERMIT },
      primaryType: "Permit",
      message: { owner: who, spender: getAddress(entry), value: p.amt, nonce: BigInt(nonceHex), deadline: order.deadline },
    };
  }

  return {
    code: 200,
    out: str({
      ...p.display, orderHash, entry: getAddress(entry), chainId,
      order, spendable: p.spendable, minOut: d.minOut, slippageBps: d.slippageBps, deadline: d.deadline,
      sign: { order: orderTyped, funds: fundsTyped },
    }),
  };
}
