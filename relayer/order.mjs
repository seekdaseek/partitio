// THE one copy of partitio's order format. The relayer, the tests and the web app all import this
// module; a second copy is how a signer and a contract quietly drift apart.
//
// THE CRYPTO IS NOT OURS. An earlier version of this file carried a hand-written Keccak-256,
// because the relayer had no dependencies. It passed the standard vectors and matched `cast keccak`
// byte for byte — and it still had no business sitting next to a funded key. viem is pinned in
// package-lock.json and does keccak, EIP-712 hashing and signing. What survives from the
// hand-rolled version is its test vectors, which now check viem instead: see relayer/parity.test.mjs.
//
// Nothing here is allowed to be a paraphrase of the contract. test/E2E_SharedModule.t.sol reads
// hashOrder off the deployed contract and compares it with this module's for random orders, and
// recomputes `spendable` the same way. If this file drifts, that test fails.

import { keccak256, toHex, hashTypedData } from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ---------------------------------------------------------------- the format

/** Must match GaslessEntry's `EIP712("partitio", "3")`. */
export const EIP712_NAME = "partitio";
export const EIP712_VERSION = "3";
export const CHAIN_ID = 4663;

/** The EIP-712 types, in the shape viem wants. viem appends referenced struct types in
 *  alphabetical order when it builds the encodeType string, which is what the contract's
 *  hard-coded ORDER_TYPEHASH also does — parity.test.mjs checks that rather than assuming it. */
export const ORDER_TYPES = {
  Guard: [
    { name: "maxDevBps", type: "uint256" },
    { name: "maxFeedAge", type: "uint256" },
  ],
  Order: [
    { name: "owner", type: "address" },
    { name: "tokenIn", type: "address" },
    { name: "amountIn", type: "uint256" },
    { name: "tokenOut", type: "address" },
    { name: "minOut", type: "uint256" },
    { name: "maxFeeUsdg", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "salt", type: "bytes32" },
    { name: "guard", type: "Guard" },
  ],
};

/** The encodeType strings, written out so they can be compared with the contract's constants. */
export const GUARD_TYPE = "Guard(uint256 maxDevBps,uint256 maxFeedAge)";
export const ORDER_TYPE =
  "Order(address owner,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut," +
  "uint256 maxFeeUsdg,uint256 deadline,bytes32 salt,Guard guard)" + GUARD_TYPE;

export const GUARD_TYPEHASH = keccak256(toHex(GUARD_TYPE));
export const ORDER_TYPEHASH = keccak256(toHex(ORDER_TYPE));

export const domainFor = (verifyingContract, chainId = CHAIN_ID) => ({
  name: EIP712_NAME,
  version: EIP712_VERSION,
  chainId,
  verifyingContract,
});

/** Normalise an order to the BigInt/hex shapes viem expects. */
export function normalizeOrder(o) {
  return {
    owner: o.owner,
    tokenIn: o.tokenIn,
    amountIn: BigInt(o.amountIn),
    tokenOut: o.tokenOut,
    minOut: BigInt(o.minOut),
    maxFeeUsdg: BigInt(o.maxFeeUsdg),
    deadline: BigInt(o.deadline),
    salt: o.salt,
    guard: { maxDevBps: BigInt(o.guard.maxDevBps), maxFeedAge: BigInt(o.guard.maxFeedAge) },
  };
}

/** The EIP-712 digest the contract's `hashOrder` returns. */
export function hashOrder(order, verifyingContract, chainId = CHAIN_ID) {
  return hashTypedData({
    domain: domainFor(verifyingContract, chainId),
    types: ORDER_TYPES,
    primaryType: "Order",
    message: normalizeOrder(order),
  });
}

/** Sign an order. The key never leaves this call. */
export async function signOrder(privateKey, order, verifyingContract, chainId = CHAIN_ID) {
  const account = privateKeyToAccount(privateKey);
  const signature = await account.signTypedData({
    domain: domainFor(verifyingContract, chainId),
    types: ORDER_TYPES,
    primaryType: "Order",
    message: normalizeOrder(order),
  });
  return {
    signature,
    v: Number("0x" + signature.slice(130, 132)),
    r: "0x" + signature.slice(2, 66),
    s: "0x" + signature.slice(66, 130),
    signer: account.address,
  };
}

// ---------------------------------------------------------------- spendable

/**
 * How much of `amountIn` GaslessEntry actually routes.
 *
 * This mirrors one line of GaslessEntry.fill:
 *     bool feeFromInput = (o.tokenIn == address(USDG));
 *     uint256 spendable = feeFromInput ? o.amountIn - fee : o.amountIn;
 *
 * On a BUY the fee is taken off the input before the swap, so the legs must cover amountIn - fee.
 * On a SELL the fee comes out of the USDG OUTPUT afterwards, so the legs cover the whole input.
 * Getting this wrong in either direction is a hard revert (LegsDoNotCoverOrder), which is why it
 * lives in one place and is asserted against the contract on a fork.
 */
export function spendableFor({ tokenIn, amountIn, fee, usdg }) {
  const a = BigInt(amountIn);
  const f = BigInt(fee);
  if (a < 0n || f < 0n) throw new Error("spendableFor: negative input");
  const feeFromInput = String(tokenIn).toLowerCase() === String(usdg).toLowerCase();
  if (!feeFromInput) return a;
  if (f > a) throw new Error("spendableFor: fee exceeds amountIn");
  return a - f;
}

// ---------------------------------------------------------------- leg scaling

/**
 * Rescale a quoted split so the legs sum to EXACTLY `spendable`, in BigInt, with no zero legs.
 *
 * GaslessEntry rejects any route whose raw legs do not sum to the spendable amount, so "close
 * enough" is a revert. The old quoter emitted chunk*allocated, which is amountIn minus
 * (amountIn mod 8) — up to 7 wei short — and its best-single override used the gross amount.
 *
 * The remainder goes to the LARGEST leg, not the last one: the largest leg is the one whose
 * execution price moves least per wei, so that is where rounding does the least damage.
 */
export function scaleLegsToSpendable(legs, spendable) {
  const target = BigInt(spendable);
  if (target <= 0n) throw new Error("scaleLegsToSpendable: target must be positive");
  if (!Array.isArray(legs) || legs.length === 0) throw new Error("scaleLegsToSpendable: no legs");

  const weights = legs.map((l) => BigInt(l.amountIn));
  if (weights.some((w) => w < 0n)) throw new Error("scaleLegsToSpendable: negative leg");
  let totalWeight = weights.reduce((a, b) => a + b, 0n);

  // Fewer wei than legs: a leg of zero is not a leg. Keep the heaviest `target` of them at 1 wei
  // each, which is the only split that both sums correctly and has no empty leg.
  if (target < BigInt(legs.length)) {
    const order = legs
      .map((_, i) => i)
      .sort((a, b) => (weights[b] > weights[a] ? 1 : weights[b] < weights[a] ? -1 : a - b));
    return order.slice(0, Number(target)).map((i) => ({ ...legs[i], amountIn: "1" }));
  }

  if (totalWeight === 0n) {
    weights.fill(1n);
    totalWeight = BigInt(legs.length);
  }

  const out = legs.map((l, i) => {
    let amt = (weights[i] * target) / totalWeight;
    if (amt < 1n) amt = 1n; // never emit a zero leg
    return { ...l, amountIn: amt };
  });

  let sum = out.reduce((a, l) => a + l.amountIn, 0n);
  const byDesc = out
    .map((_, i) => i)
    .sort((a, b) => (out[b].amountIn > out[a].amountIn ? 1 : out[b].amountIn < out[a].amountIn ? -1 : a - b));

  if (sum < target) {
    out[byDesc[0]].amountIn += target - sum;
  } else if (sum > target) {
    let excess = sum - target;
    for (const i of byDesc) {
      if (excess === 0n) break;
      const spare = out[i].amountIn - 1n; // keep at least 1 wei
      const take = spare < excess ? spare : excess;
      out[i].amountIn -= take;
      excess -= take;
    }
    if (excess !== 0n) throw new Error("scaleLegsToSpendable: cannot fit target without a zero leg");
  }

  return out.map((l) => ({ ...l, amountIn: l.amountIn.toString() }));
}

// ---------------------------------------------------------------- client defaults

/** Slippage above this is refused outright rather than signed. */
export const MAX_SLIPPAGE_BPS = 300;
export const DEFAULT_SLIPPAGE_BPS = 50;
export const DEFAULT_DEADLINE_SECONDS = 120;
export const FEED_AGE_HEADROOM_SECONDS = 60;

/**
 * The client-side defaults for a MARKET order, in one place so the relayer and the web app cannot
 * disagree about them.
 *
 * `maxFeedAge` is the feed's age at quote time plus the deadline plus headroom: the order must
 * stay fillable for as long as it is live, but no longer, so a relayer cannot sit on it waiting
 * for the reference to go stale.
 */
export function marketOrderDefaults({ quotedNet, feedAgeAtQuote, nowSeconds, slippageBps = DEFAULT_SLIPPAGE_BPS }) {
  if (slippageBps > MAX_SLIPPAGE_BPS) {
    throw new Error(`slippage ${slippageBps} bps exceeds the ${MAX_SLIPPAGE_BPS} bps maximum`);
  }
  const net = BigInt(quotedNet);
  const minOut = (net * BigInt(10_000 - slippageBps)) / 10_000n;
  if (minOut <= 0n) throw new Error("marketOrderDefaults: quoted net is too small to floor");
  return {
    minOut,
    deadline: BigInt(nowSeconds) + BigInt(DEFAULT_DEADLINE_SECONDS),
    maxFeedAge:
      BigInt(feedAgeAtQuote) + BigInt(DEFAULT_DEADLINE_SECONDS) + BigInt(FEED_AGE_HEADROOM_SECONDS),
    slippageBps,
  };
}

/** What the relayer refuses to accept from a client, regardless of what it signed. */
export function rejectReasonForMarketOrder(order, slippageBps) {
  if (BigInt(order.minOut) === 0n) return "minOut must be greater than zero";
  if (slippageBps !== undefined && slippageBps > MAX_SLIPPAGE_BPS) {
    return `slippage ${slippageBps} bps exceeds the ${MAX_SLIPPAGE_BPS} bps maximum`;
  }
  if (BigInt(order.guard.maxFeedAge) === 0n) return "maxFeedAge must be greater than zero";
  return null;
}
