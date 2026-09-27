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

import { getAddress, keccak256, toHex } from "viem";
import * as CFG from "./config.mjs";
import { call } from "./rpc.mjs";
import { onChainQuote, HIDDEN } from "./quote.mjs";
import { ORDER_TYPES, domainFor, hashOrder, marketOrderDefaults, DEFAULT_SLIPPAGE_BPS, MAX_SLIPPAGE_BPS } from "./order.mjs";

/** The fee the relayer asks for, in basis points of the USDG side. MAX_FEE_BPS (50) is the hard cap. */
export const FEE_BPS = Number(process.env.PARTITIO_FEE_BPS || 30);
/** The oracle band the app signs by default - measured to refuse 0.8% of $1k trades (docs/REVIEW-FIXES.md §11). */
export const APP_BAND_BPS = 200;

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

/**
 * @returns {{code:number, out:object}}
 */
export async function prepareOrder({ ticker, direction, amountIn, owner, slippageBps = DEFAULT_SLIPPAGE_BPS },
  { entry = CFG.GASLESS_ENTRY, chainId = CFG.CHAIN_ID } = {}) {
  if (!entry) return { code: 503, out: { error: "trading paused", reason: "contracts-not-deployed" } };
  if (!ticker || !["buy", "sell"].includes(direction)) return { code: 400, out: { error: "ticker and direction (buy|sell) are required" } };
  if (HIDDEN.has(ticker)) return { code: 400, out: { error: `${ticker} is not offered in v1` } };
  let who;
  try { who = getAddress(owner); } catch { return { code: 400, out: { error: "owner must be an address" } }; }
  let amt;
  try { amt = BigInt(amountIn); } catch { return { code: 400, out: { error: "amountIn must be an integer string in base units" } }; }
  if (amt <= 0n) return { code: 400, out: { error: "amountIn must be positive" } };
  if (slippageBps > MAX_SLIPPAGE_BPS) return { code: 400, out: { error: `slippage above ${MAX_SLIPPAGE_BPS} bps` } };

  const TOK = (await import("./tokens.json", { with: { type: "json" } })).default.tokens;
  const stock = TOK[ticker] && getAddress(TOK[ticker]);
  if (!stock) return { code: 400, out: { error: `unknown ticker ${ticker}` } };
  const sell = direction === "sell";

  // buy: the fee comes off the USDG input before the swap; sell: out of the USDG proceeds
  const buyFee = sell ? 0n : (amt * BigInt(FEE_BPS) + 9_999n) / 10_000n;
  const spendable = amt - buyFee;
  if (spendable <= 0n) return { code: 400, out: { error: "amount too small to cover the fee" } };

  const q = await onChainQuote(ticker, direction, spendable);
  if (!q.legs?.length || !q.partitio || BigInt(q.partitio) === 0n) {
    return { code: 422, out: { error: "no route", reason: "no committed venue quoted this pair at this size" } };
  }
  const gross = BigInt(q.partitio);
  const sellFee = sell ? (gross * BigInt(FEE_BPS) + 9_999n) / 10_000n : 0n;
  const fee = sell ? sellFee : buyFee;
  const net = sell ? gross - sellFee : gross;

  // the USD size, for the public-beta cap: USDG is the notional on a buy, the proceeds on a sell
  const notionalUsd = Number(sell ? gross : amt) / 1e6;
  if (notionalUsd > CFG.MAX_TRADE_USD) {
    return { code: 400, out: { error: "over the public-beta size cap", capUsd: CFG.MAX_TRADE_USD, notionalUsd } };
  }

  // Refuse before a signature exists, in the words the contract would have used after it
  const belowBps = q.oracleDevBps == null ? null : -q.oracleDevBps;
  if (belowBps != null && belowBps >= APP_BAND_BPS) {
    return { code: 422, out: {
      error: sell ? "sells paused" : "buy refused",
      reason: `the best on-chain price is ${(belowBps / 100).toFixed(1)}% below Chainlink, outside the ${APP_BAND_BPS / 100}% band`,
      oracleDevBps: q.oracleDevBps } };
  }

  const head = await call("eth_getBlockByNumber", ["latest", false]);
  const now = Number(BigInt(head.timestamp));
  const feedAge = q.oracleUpdatedAt ? Math.max(0, now - Number(q.oracleUpdatedAt)) : 0;
  const d = marketOrderDefaults({ quotedNet: net, feedAgeAtQuote: feedAge, nowSeconds: now, slippageBps });

  const order = {
    owner: who,
    tokenIn: sell ? stock : getAddress(CFG.USDG),
    amountIn: amt,
    tokenOut: sell ? getAddress(CFG.USDG) : stock,
    minOut: d.minOut,
    maxFeeUsdg: fee,
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

  let authTyped;
  if (!sell) {
    authTyped = {
      domain: { ...USDG_DOMAIN_FIELDS, chainId, verifyingContract: getAddress(CFG.USDG) },
      types: { EIP712Domain: EIP712_DOMAIN, ReceiveWithAuthorization: RECEIVE },
      primaryType: "ReceiveWithAuthorization",
      message: { from: who, to: getAddress(entry), value: amt, validAfter: 0n, validBefore: order.deadline, nonce: orderHash },
    };
  } else {
    const dom = await stockDomain(stock);
    const nonceHex = await call("eth_call", [{ to: stock, data: SEL.nonces + who.slice(2).toLowerCase().padStart(64, "0") }, "latest"]);
    authTyped = {
      domain: dom,
      types: { EIP712Domain: EIP712_DOMAIN, Permit: PERMIT },
      primaryType: "Permit",
      message: { owner: who, spender: getAddress(entry), value: amt, nonce: BigInt(nonceHex), deadline: order.deadline },
    };
  }

  return {
    code: 200,
    out: str({
      ticker, direction, orderHash, entry: getAddress(entry), chainId,
      order, fee, feeBps: FEE_BPS, spendable, expectedOut: net, minOut: d.minOut, slippageBps: d.slippageBps,
      deadline: d.deadline, notionalUsd,
      route: {
        legs: q.legs.map((l) => ({ venue: l.venue, kind: l.kind, family: l.family, amountIn: l.amountIn, amountOut: l.amountOut })),
        venuesUsed: q.venuesUsed, bestSingle: q.bestSingle, bestSingleFamily: q.bestSingleFamily, partitio: q.partitio,
        splitGainBps: q.bestSingle && BigInt(q.bestSingle) > 0n
          ? Number(((BigInt(q.partitio) - BigInt(q.bestSingle)) * 10_000n) / BigInt(q.bestSingle)) : null,
      },
      oracle: { devBps: q.oracleDevBps, updatedAt: q.oracleUpdatedAt, feedAgeSeconds: feedAge, desc: q.oracleDesc },
      sign: { order: orderTyped, funds: authTyped },
    }),
  };
}
