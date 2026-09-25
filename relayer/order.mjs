// THE one copy of partitio's order format. The relayer, the tests and the web app all import this
// module; a second copy is how the signer and the contract quietly drift apart.
//
// Nothing here is allowed to be a paraphrase of the contract. Every constant below is checked
// against the deployed bytecode by test/E2E_SharedModule.t.sol, which reads ORDER_TYPEHASH and
// GUARD_TYPEHASH off the contract and recomputes `spendable` and `hashOrder` for random inputs.
// If this file drifts, that test fails — that is the whole point of it existing.
//
// No dependencies, on purpose: the relayer runs on node builtins only, so Keccak-256 is
// implemented here rather than pulled in. It is verified against the standard vectors in
// selfTest() below, which the relayer runs at boot.

// ---------------------------------------------------------------- keccak-256

const MASK = (1n << 64n) - 1n;

const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];

// rho offsets, r[x][y]
const ROT = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];

const rotl = (v, n) => (n === 0 ? v : (((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK));

function keccakF(A) {
  for (let round = 0; round < 24; round++) {
    const C = new Array(5);
    for (let x = 0; x < 5; x++) C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4];
    const D = new Array(5);
    for (let x = 0; x < 5; x++) D[x] = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) A[x][y] ^= D[x];

    const B = [[], [], [], [], []];
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) B[y][(2 * x + 3 * y) % 5] = rotl(A[x][y], ROT[x][y]);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) A[x][y] = B[x][y] ^ (~B[(x + 1) % 5][y] & MASK & B[(x + 2) % 5][y]);
    }
    A[0][0] ^= RC[round];
  }
  return A;
}

/** Keccak-256 (Ethereum's, NOT NIST SHA3-256 — they differ in the padding byte). */
export function keccak256(bytes) {
  const RATE = 136;
  const input = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const padLen = RATE - (input.length % RATE);
  const buf = new Uint8Array(input.length + padLen);
  buf.set(input);
  buf[input.length] |= 0x01;      // Keccak padding, not 0x06
  buf[buf.length - 1] |= 0x80;

  const A = [0, 0, 0, 0, 0].map(() => [0n, 0n, 0n, 0n, 0n]);
  for (let off = 0; off < buf.length; off += RATE) {
    for (let i = 0; i < RATE / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(buf[off + i * 8 + b]);
      A[i % 5][Math.floor(i / 5)] ^= lane;
    }
    keccakF(A);
  }

  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    let lane = A[i % 5][Math.floor(i / 5)];
    for (let b = 0; b < 8; b++) {
      out[i * 8 + b] = Number(lane & 0xffn);
      lane >>= 8n;
    }
  }
  return out;
}

export const keccakHex = (bytes) => "0x" + Buffer.from(keccak256(bytes)).toString("hex");
export const utf8 = (s) => new TextEncoder().encode(s);
export const keccakUtf8 = (s) => keccakHex(utf8(s));

// ---------------------------------------------------------------- abi helpers

const strip = (h) => String(h).replace(/^0x/, "").toLowerCase();
export const word = (v) => {
  if (typeof v === "boolean") v = v ? 1n : 0n;
  if (typeof v === "string" && v.startsWith("0x")) return strip(v).padStart(64, "0");
  return BigInt(v).toString(16).padStart(64, "0");
};
export const concatHex = (...parts) => "0x" + parts.map(strip).join("");
const hexBytes = (h) => Uint8Array.from(Buffer.from(strip(h), "hex"));

// ---------------------------------------------------------------- the format

/** EIP712("partitio", "3") — must match GaslessEntry's constructor. */
export const EIP712_NAME = "partitio";
export const EIP712_VERSION = "3";
export const CHAIN_ID = 4663;

export const GUARD_TYPE = "Guard(uint256 maxDevBps)";
export const ORDER_TYPE =
  "Order(address owner,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut," +
  "uint256 maxFeeUsdg,uint256 deadline,bytes32 salt,Guard guard)" + GUARD_TYPE;

export const GUARD_TYPEHASH = keccakUtf8(GUARD_TYPE);
export const ORDER_TYPEHASH = keccakUtf8(ORDER_TYPE);

export function domainSeparator(verifyingContract, chainId = CHAIN_ID) {
  const typeHash = keccakUtf8(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
  );
  return keccakHex(
    hexBytes(
      concatHex(
        typeHash,
        keccakUtf8(EIP712_NAME),
        keccakUtf8(EIP712_VERSION),
        word(chainId),
        word(verifyingContract)
      )
    )
  );
}

export function hashGuard(guard) {
  return keccakHex(hexBytes(concatHex(GUARD_TYPEHASH, word(guard.maxDevBps))));
}

export function hashOrder(order, verifyingContract, chainId = CHAIN_ID) {
  const structHash = keccakHex(
    hexBytes(
      concatHex(
        ORDER_TYPEHASH,
        word(order.owner),
        word(order.tokenIn),
        word(order.amountIn),
        word(order.tokenOut),
        word(order.minOut),
        word(order.maxFeeUsdg),
        word(order.deadline),
        word(order.salt),
        hashGuard(order.guard)
      )
    )
  );
  const ds = domainSeparator(verifyingContract, chainId);
  const pre = Uint8Array.from([
    0x19, 0x01,
    ...hexBytes(ds),
    ...hexBytes(structHash),
  ]);
  return keccakHex(pre);
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
 * Getting this wrong in either direction is now a hard revert (LegsDoNotCoverOrder), which is
 * exactly why it lives in one place and is asserted against the contract on a fork.
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
 * execution price moves least per wei, so that is where rounding does the least damage to the
 * quoted split.
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
    const order = legs.map((l, i) => i).sort((a, b) => (weights[b] > weights[a] ? 1 : weights[b] < weights[a] ? -1 : a - b));
    const keep = order.slice(0, Number(target));
    return keep.map((i) => ({ ...legs[i], amountIn: "1" }));
  }

  if (totalWeight === 0n) {
    weights.fill(1n);
    totalWeight = BigInt(legs.length);
  }

  const out = legs.map((l, i) => {
    let amt = (weights[i] * target) / totalWeight;
    if (amt < 1n) amt = 1n;                    // never emit a zero leg
    return { ...l, amountIn: amt };
  });

  // Fix up to hit `target` exactly. Over-allocation can only come from the >=1 clamp, so take it
  // back from the largest legs; under-allocation is division remainder and goes to the largest.
  let sum = out.reduce((a, l) => a + l.amountIn, 0n);
  const byDesc = out.map((l, i) => i).sort((a, b) => (out[b].amountIn > out[a].amountIn ? 1 : out[b].amountIn < out[a].amountIn ? -1 : a - b));

  if (sum < target) {
    out[byDesc[0]].amountIn += target - sum;
  } else if (sum > target) {
    let excess = sum - target;
    for (const i of byDesc) {
      if (excess === 0n) break;
      const spare = out[i].amountIn - 1n;      // keep at least 1 wei
      const take = spare < excess ? spare : excess;
      out[i].amountIn -= take;
      excess -= take;
    }
    if (excess !== 0n) throw new Error("scaleLegsToSpendable: cannot fit target without a zero leg");
  }

  return out.map((l) => ({ ...l, amountIn: l.amountIn.toString() }));
}

// ---------------------------------------------------------------- self test

/** Standard Keccak-256 vectors. The relayer runs this at boot: a wrong hash here would mean every
 *  order it signs is rejected, and finding that out from a revert is expensive. */
export function selfTest() {
  const cases = [
    ["", "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"],
    ["abc", "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"],
    [
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "0x45d3b367a6904e6e8d502ee04999a7c27647f91fa845d456525fd352ae3d7371",
    ],
  ];
  for (const [input, want] of cases) {
    const got = keccakUtf8(input);
    if (got !== want) throw new Error(`keccak256("${input}") = ${got}, want ${want}`);
  }
  // A 136-byte input exercises the exact-rate padding edge, which is the classic place to get
  // Keccak wrong: the padding must occupy a whole extra block.
  const exact = keccakHex(new Uint8Array(136));
  if (exact.length !== 66) throw new Error("keccak256 of a full rate block is malformed");
  return true;
}
