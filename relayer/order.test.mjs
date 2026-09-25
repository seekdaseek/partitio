// Property tests for the shared order module. Pure JS, no RPC, no chain — run with:
//   node relayer/order.test.mjs
//
// The properties here are the ones GaslessEntry turns into a revert:
//   sum(legs) == spendable exactly            -> LegsDoNotCoverOrder
//   every leg >= 1                            -> NothingRouted on a zero-amount leg
// so a failure here is a transaction that would burn the relayer's gas on-chain.

import {
  scaleLegsToSpendable,
  spendableFor,
  GUARD_TYPEHASH,
  ORDER_TYPEHASH,
  hashOrder,
} from "./order.mjs";

// The keccak vectors and the `cast` cross-check moved to relayer/parity.test.mjs when the
// hand-rolled implementation was replaced by viem. This file owns the arithmetic: leg scaling and
// the spendable formula, neither of which is crypto.

let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) {
    failures++;
    console.error(`  FAIL  ${name}${detail ? " :: " + detail : ""}`);
  }
};

// Deterministic PRNG so a failure is reproducible from the seed alone.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

console.log("typehash shape (parity with the contract lives in parity.test.mjs)");
check("typehashes are 32 bytes", GUARD_TYPEHASH.length === 66 && ORDER_TYPEHASH.length === 66);

// ---------------------------------------------------------------- spendableFor

console.log("spendableFor");
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
check(
  "buy: the fee comes off the input",
  spendableFor({ tokenIn: USDG, amountIn: 1000n, fee: 5n, usdg: USDG }) === 995n
);
check(
  "sell: the fee comes out of the output, so the legs cover the whole input",
  spendableFor({ tokenIn: AAPL, amountIn: 1000n, fee: 5n, usdg: USDG }) === 1000n
);
check(
  "case-insensitive on the token address",
  spendableFor({ tokenIn: USDG.toLowerCase(), amountIn: 1000n, fee: 5n, usdg: USDG.toUpperCase() }) === 995n
);
try {
  spendableFor({ tokenIn: USDG, amountIn: 10n, fee: 11n, usdg: USDG });
  check("fee > amountIn must throw", false);
} catch {
  check("fee > amountIn must throw", true);
}

// ---------------------------------------------------------------- leg scaling

console.log("scaleLegsToSpendable — 10,000 random cases plus the named edges");

const mkLegs = (n, rnd) =>
  Array.from({ length: n }, (_, i) => ({
    venue: `0x${String(i).padStart(40, "0")}`,
    kind: "v3",
    amountIn: (BigInt(Math.floor(rnd() * 1_000_000)) + 1n).toString(),
  }));

const PRIMES = [
  2n, 3n, 5n, 7n, 11n, 13n, 101n, 7919n, 104729n, 1000003n, 32416190071n,
  2305843009213693951n,
];
const MAX_UINT96 = (1n << 96n) - 1n;   // far above any real order, still exact in BigInt

const named = [
  1n, 2n, 3n, 7n, 8n, 9n, 15n, 16n, 17n,
  ...PRIMES,
  12_345_678n,           // the amount that actually produced short legs
  999_999_999n,
  1_000_000_000n,
  MAX_UINT96,
  (1n << 128n) - 1n,
];

const rnd = mulberry32(0xC0FFEE);
let cases = 0;
let clampedCases = 0;

function runCase(target, nLegs, label) {
  cases++;
  const legs = mkLegs(nLegs, rnd);
  let out;
  try {
    out = scaleLegsToSpendable(legs, target);
  } catch (e) {
    check(`${label} target=${target} n=${nLegs} threw`, false, e.message);
    return;
  }
  const sum = out.reduce((a, l) => a + BigInt(l.amountIn), 0n);
  check(`${label} sum == target (target=${target}, n=${nLegs})`, sum === target, `got ${sum}`);
  const minLeg = out.reduce((m, l) => (BigInt(l.amountIn) < m ? BigInt(l.amountIn) : m), 1n << 200n);
  check(`${label} every leg >= 1 (target=${target}, n=${nLegs})`, minLeg >= 1n, `min ${minLeg}`);
  check(`${label} amountIn is a string (target=${target})`, out.every((l) => typeof l.amountIn === "string"));
  check(
    `${label} no more legs than we started with (target=${target})`,
    out.length <= nLegs && out.length >= 1
  );
  if (target < BigInt(nLegs)) clampedCases++;
}

// the named edges, against every leg count the quoter can emit
for (const t of named) {
  for (let n = 1; n <= 8; n++) runCase(t, n, "edge");
}

// 10,000 random cases
for (let i = 0; i < 10_000; i++) {
  const magnitude = Math.floor(rnd() * 20);
  const base = BigInt(Math.floor(rnd() * 1_000_000) + 1);
  const target = base * 10n ** BigInt(magnitude) + BigInt(Math.floor(rnd() * 8));
  const nLegs = 1 + Math.floor(rnd() * 8);
  runCase(target, nLegs, "random");
}

// the specific shape that broke it: K=8 chunking leaves a remainder
console.log("the original defect — K=8 integer division");
for (const amt of [12_345_678n, 500_000_001n, 999_999_999n, 7n]) {
  const chunk = amt / 8n;
  const greedyLegs = [
    { venue: "0xa", amountIn: (chunk * 5n).toString() },
    { venue: "0xb", amountIn: (chunk * 3n).toString() },
  ];
  const rawSum = greedyLegs.reduce((a, l) => a + BigInt(l.amountIn), 0n);
  const fixed = scaleLegsToSpendable(greedyLegs, amt);
  const sum = fixed.reduce((a, l) => a + BigInt(l.amountIn), 0n);
  check(`greedy legs were short by ${amt - rawSum} and are now exact (amt=${amt})`, sum === amt, `got ${sum}`);
}

// ---------------------------------------------------------------- hashOrder shape

console.log("hashOrder");
const order = {
  owner: "0x000000000000000000000000000000000000dead",
  tokenIn: USDG,
  amountIn: 1_000_000_000n,
  tokenOut: AAPL,
  minOut: 1n,
  maxFeeUsdg: 5_000_000n,
  deadline: 1_790_000_000n,
  salt: "0x" + "11".repeat(32),
  guard: { maxDevBps: 300n, maxFeedAge: 3600n },
};
const h1 = hashOrder(order, "0x000000000000000000000000000000000000beef");
const h2 = hashOrder(order, "0x000000000000000000000000000000000000beef");
const h3 = hashOrder(order, "0x000000000000000000000000000000000000cafe");
const h4 = hashOrder({ ...order, minOut: 2n }, "0x000000000000000000000000000000000000beef");
check("hashOrder is deterministic", h1 === h2);
check("hashOrder binds the verifying contract", h1 !== h3);
check("hashOrder binds every field (minOut)", h1 !== h4);
check("hashOrder is 32 bytes", h1.length === 66);

// ---------------------------------------------------------------- result

console.log(`\n${cases} scaling cases (${clampedCases} with fewer wei than legs), ${failures} failures`);
if (failures > 0) {
  console.error("FAILED");
  process.exit(1);
}
console.log("OK");
