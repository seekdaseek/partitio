// Order submission: validate, re-quote, SIMULATE, and only then send.
//
// The rule this file exists for: the relayer never broadcasts a transaction that simulates to a
// revert. A revert still burns the float, and the float is 0.0002 ETH. Every refusal below happens
// before a transaction exists, and each one returns a reason the UI can show rather than a bare
// failure.
//
// The ABI is read from the forge artifact rather than hand-copied, so the encoder cannot drift
// from the contract the way a transcribed ABI eventually does.

import fs from "node:fs";
import path from "node:path";
import { encodeFunctionData, decodeErrorResult, recoverTypedDataAddress } from "viem";

import * as CFG from "./config.mjs";
import { call } from "./rpc.mjs";
import { onChainQuote, HIDDEN } from "./quote.mjs";
import {
  ORDER_TYPES, domainFor, normalizeOrder, spendableFor, scaleLegsToSpendable,
  rejectReasonForMarketOrder, MAX_SLIPPAGE_BPS, hashOrder,
} from "./order.mjs";
import { createLocks } from "./sender.mjs";

// One per process: the relayer is a single process, and `executed` on-chain is the durable record.
const LOCKS = createLocks();

const HERE = path.dirname(new URL(import.meta.url).pathname);

/** The real ABI, from the build. A hand-copied one drifts; this cannot. */
let ABI = null;
function abi() {
  if (ABI) return ABI;
  const p = path.resolve(HERE, "..", "out", "GaslessEntry.sol", "GaslessEntry.json");
  if (!fs.existsSync(p)) {
    throw new Error(`GaslessEntry artifact not found at ${p} — run \`forge build\` first`);
  }
  ABI = JSON.parse(fs.readFileSync(p, "utf8")).abi;
  return ABI;
}

/** Every custom error the contracts can raise, so a simulated revert comes back named. */
let ERROR_ABI = null;
function errorAbi() {
  if (ERROR_ABI) return ERROR_ABI;
  const out = [];
  for (const f of ["GaslessEntry.sol/GaslessEntry.json", "PartitioRouterV2.sol/PartitioRouterV2.json"]) {
    const p = path.resolve(HERE, "..", "out", f);
    // Loud, like abi(): skipping a missing artifact silently degraded every revert to "unknown",
    // which a fresh clone hit by running the tests before `forge build`.
    if (!fs.existsSync(p)) throw new Error(`${f} not found under out/ - run \`forge build\` first`);
    out.push(...JSON.parse(fs.readFileSync(p, "utf8")).abi.filter((x) => x.type === "error"));
  }
  // OracleGuard is a library; its errors are inlined into both callers, so they arrive via the
  // two ABIs above. Add the ERC20 ones the tokens themselves raise.
  out.push(
    { type: "error", name: "ERC20InsufficientBalance", inputs: [
      { name: "sender", type: "address" }, { name: "balance", type: "uint256" }, { name: "needed", type: "uint256" }] },
    { type: "error", name: "ERC20InsufficientAllowance", inputs: [
      { name: "spender", type: "address" }, { name: "allowance", type: "uint256" }, { name: "needed", type: "uint256" }] },
  );
  ERROR_ABI = out;
  return ERROR_ABI;
}

/** Turn revert data into something a person can act on. */
export function explainRevert(data) {
  if (!data || data === "0x") return { name: "revert", detail: "no reason returned" };
  // Error(string)
  if (data.startsWith("0x08c379a0")) {
    try {
      const { args } = decodeErrorResult({ abi: [{ type: "error", name: "Error", inputs: [{ type: "string" }] }], data });
      return { name: "Error", detail: String(args[0]) };
    } catch { /* fall through */ }
  }
  if (data.startsWith("0x4e487b71")) return { name: "Panic", detail: `panic ${data.slice(-2)}` };
  try {
    const { errorName, args } = decodeErrorResult({ abi: errorAbi(), data });
    return { name: errorName, detail: (args ?? []).map(String).join(", ") };
  } catch {
    return { name: "unknown", detail: data.slice(0, 74) };
  }
}

/** Human sentence for the refusals a trader will actually hit. */
export function refusalSentence(err, ctx = {}) {
  switch (err.name) {
    case "BelowOracleFloor": {
      // A floor breach with got == 0 is not a price problem, it is OUR problem. The accepted
      // aggregator branch falls through to partitio with `spendable - spent`, and on a buy a
      // remainder of 1-99 wei of USDG buys zero stock: the router's own guard then sees spent > 0
      // with nothing delivered and reverts the whole fill. Measured cliff: 0 wei settles, 1 and
      // 10 wei revert, 100 wei and above settle. Nothing is lost - the revert rolls back
      // `executed[orderHash]` and no funds move - but telling a trader "the price moved" when the
      // real cause is how WE sized the aggregator's calldata is the kind of lie that wastes a
      // support cycle. Re-quoting with a remainder of zero or a material size fixes it.
      const got = String(err.detail || "").split(",")[0].trim();
      if (got === "0") {
        return "the route left an unroutable remainder — this is a relayer bug, not your order; re-quoting";
      }
      return ctx.direction === "sell" && ctx.oracleDevBps != null
        ? `sells paused: the best on-chain price is ${Math.abs(ctx.oracleDevBps / 100).toFixed(1)}% below Chainlink`
        : "the fill would land below the Chainlink floor you signed";
    }
    case "FeedOlderThanSignerAllows":
      return "the price reference is older than this order allows; re-quote and sign again";
    case "MinOutRequired":
      return "the order has no minimum output; it would be unsafe to fill";
    case "LegsDoNotCoverOrder":
      return "the route does not cover the order — this is a relayer bug, not your order";
    case "Expired":
      return "the order expired before it could be filled";
    case "AlreadyExecuted":
      return "this order was already filled";
    case "FeeAboveMax":
      return "the fee exceeds what the order allows";
    default:
      return `would revert: ${err.name}${err.detail ? " (" + err.detail + ")" : ""}`;
  }
}

// ---------------------------------------------------------------- per-address limits

const perOwner = new Map();
export function ownerRateOk(owner, maxPerMin = 6) {
  const now = Date.now();
  const w = (perOwner.get(owner) || []).filter((t) => now - t < 60_000);
  if (w.length >= maxPerMin) { perOwner.set(owner, w); return false; }
  w.push(now);
  perOwner.set(owner, w);
  return true;
}

// ---------------------------------------------------------------- the submit path

/**
 * @returns {{code:number, out:object}} — `out.sent` is only ever true when a transaction was
 * actually broadcast, which requires `send` to be supplied by the caller.
 */
export async function handleOrder(body, { send = null, entryAddress = CFG.GASLESS_ENTRY, locks = LOCKS } = {}) {
  const t0 = Date.now();
  const { order, auth, fee, slippageBps, ticker, direction } = body || {};

  if (!order || !auth || fee === undefined) {
    return { code: 400, out: { error: "order, auth and fee are required" } };
  }
  if (!entryAddress) {
    return { code: 503, out: { error: "trading paused", reason: "contracts-not-deployed" } };
  }
  if (ticker && HIDDEN.has(ticker)) {
    return { code: 400, out: { error: `${ticker} is not offered in v1`,
      reason: "priced by a Uniswap-pool-derived feed; a pool price cannot guard a trade that moves that pool" } };
  }

  // 1. the refusals that need no chain access at all
  const why = rejectReasonForMarketOrder(order, slippageBps);
  if (why) return { code: 400, out: { error: "order refused", reason: why, sent: false } };
  if (slippageBps !== undefined && slippageBps > MAX_SLIPPAGE_BPS) {
    return { code: 400, out: { error: "order refused", reason: `slippage above ${MAX_SLIPPAGE_BPS} bps`, sent: false } };
  }
  if (!ownerRateOk(String(order.owner).toLowerCase())) {
    return { code: 429, out: { error: "rate limited", scope: "owner", sent: false } };
  }

  // 2. the signature must actually be the owner's, checked here rather than discovered on-chain
  let recovered;
  try {
    recovered = await recoverTypedDataAddress({
      domain: domainFor(entryAddress, CFG.CHAIN_ID),
      types: ORDER_TYPES,
      primaryType: "Order",
      message: normalizeOrder(order),
      signature: auth.signature ?? { r: auth.r, s: auth.s, v: BigInt(auth.v) },
    });
  } catch (e) {
    return { code: 400, out: { error: "bad signature", detail: String(e.message || e), sent: false } };
  }
  if (recovered.toLowerCase() !== String(order.owner).toLowerCase()) {
    return { code: 400, out: { error: "signature does not match owner", recovered, sent: false } };
  }

  // 3. RE-QUOTE AT SUBMIT TIME. The legs the client saw may be minutes old, and the contract
  //    rejects any route whose legs do not sum to exactly the spendable amount.
  const spendable = spendableFor({
    tokenIn: order.tokenIn, amountIn: order.amountIn, fee, usdg: CFG.USDG,
  });
  if (spendable <= 0n) {
    return { code: 400, out: { error: "order refused", reason: "fee leaves nothing to route", sent: false } };
  }

  let quote = null;
  let legs = body.legs ?? null;
  if (ticker && direction) {
    quote = await onChainQuote(ticker, direction, spendable);
    legs = quote.legs;
  }
  if (!legs || legs.length === 0) {
    return { code: 400, out: { error: "no route", reason: "no venue quoted this pair at this size", sent: false } };
  }
  legs = scaleLegsToSpendable(legs, spendable);

  const legSum = legs.reduce((a, l) => a + BigInt(l.amountIn), 0n);
  if (legSum !== spendable) {
    // Belt: scaleLegsToSpendable guarantees this, and a mismatch here is our bug, not the user's.
    return { code: 500, out: { error: "internal", reason: `legs sum ${legSum} != spendable ${spendable}`, sent: false } };
  }

  // 4. SIMULATE. Nothing is broadcast until this returns cleanly.
  const route = {
    aggregator: body.aggregator ?? "0x0000000000000000000000000000000000000000",
    callData: body.callData ?? "0x",
    aggMinOut: BigInt(body.aggMinOut ?? 0),
    legs: legs.map((l) => ({ venue: l.venueStruct ?? l.venue, proof: l.proof ?? [], amountIn: BigInt(l.amountIn) })),
  };

  let data;
  try {
    data = encodeFunctionData({
      abi: abi(),
      functionName: "fill",
      args: [normalizeOrder(order), normalizeAuth(auth), route, BigInt(fee)],
    });
  } catch (e) {
    return { code: 400, out: { error: "could not encode fill", detail: String(e.message || e), sent: false } };
  }

  // 5. ONE FILL AT A TIME per order and per wallet. Both locks are taken before the first
  //    simulation and held until the transaction is mined or abandoned: two submissions of the same
  //    order, or two orders spending the same balance, both simulate cleanly against today's state
  //    and one of them then reverts on-chain having paid for its gas.
  const orderHash = hashOrder(order, entryAddress, CFG.CHAIN_ID);
  const busy = locks.acquire(orderHash, order.owner);
  if (busy) return { code: busy.code, out: { error: "not sent", reason: busy.reason, orderHash, sent: false } };

  try {
    const from = send?.address ?? body.relayerAddress ?? CFG.RELAYER_ADDRESS ?? null;
    const sim = await simulate({ to: entryAddress, from, data });
    if (!sim.ok) {
      const err = explainRevert(sim.data);
      return {
        code: 422,
        out: {
          error: "would revert — not sent",
          reason: refusalSentence(err, { direction, oracleDevBps: quote?.oracleDevBps }),
          revert: err,
          orderHash,
          sent: false,
          txs: 0,
          ms: Date.now() - t0,
        },
      };
    }

    // 6. Only now may anything be broadcast, and only if the caller supplied a sender.
    if (!send) {
      return { code: 200, out: { simulated: true, sent: false, willReceive: sim.result ?? null, orderHash,
        legs: legs.length, spendable: spendable.toString(), ms: Date.now() - t0 } };
    }
    let r;
    try {
      // re-simulated INSIDE the send queue, immediately before signing: state may have moved
      // while this fill waited behind another one
      r = await send.send({ to: entryAddress, data, label: orderHash.slice(0, 10),
        resimulate: () => simulate({ to: entryAddress, from: send.address, data }) });
    } catch (e) {
      if (e.notSent) {
        const err = explainRevert(e.revert);
        return { code: 422, out: { error: "would revert — not sent",
          reason: refusalSentence(err, { direction, oracleDevBps: quote?.oracleDevBps }),
          revert: err, orderHash, sent: false, txs: 0, ms: Date.now() - t0 } };
      }
      return { code: 502, out: { error: "send failed", detail: String(e.message || e).slice(0, 300),
        orderHash, sent: false, ms: Date.now() - t0 } };
    }
    return {
      code: r.ok ? 200 : 500,
      out: {
        simulated: true, sent: true, mined: true, ok: r.ok, orderHash,
        txHash: r.hash, gasUsed: r.gasUsed.toString(), effectiveGasPrice: r.effectiveGasPrice.toString(),
        replacements: r.replacements, nonce: r.nonce, attempts: r.attempts, ms: Date.now() - t0,
        ...(r.ok ? {} : { error: "mined but reverted — the simulation and the chain disagreed" }),
      },
    };
  } finally {
    locks.release(orderHash, order.owner);
  }
}

function normalizeAuth(a) {
  return {
    v: Number(a.v), r: a.r, s: a.s,
    pv: Number(a.pv), pr: a.pr, ps: a.ps,
    validAfter: BigInt(a.validAfter ?? 0),
    validBefore: BigInt(a.validBefore ?? 0),
  };
}

/** eth_call against latest. Returns {ok, result} or {ok:false, data} with the revert payload. */
export async function simulate({ to, from, data }) {
  try {
    const params = [{ to, data, ...(from ? { from } : {}) }, "latest"];
    const res = await call("eth_call", params);
    return { ok: true, result: res };
  } catch (e) {
    // rpc.mjs surfaces the node's error; dig out revert data wherever the node put it
    const raw = e?.data ?? e?.cause?.data ?? e?.error?.data ?? null;
    const m = typeof e?.message === "string" ? e.message.match(/0x[0-9a-fA-F]{8,}/) : null;
    return { ok: false, data: raw ?? (m ? m[0] : null) };
  }
}
