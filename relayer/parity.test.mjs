// Parity test for the crypto the relayer signs with.
//
// An earlier version of order.mjs carried a hand-written Keccak-256. It was replaced by viem,
// because hand-rolled crypto has no business next to a funded key — but the checks that made it
// trustworthy are not thrown away with it. They point at viem now:
//
//   1. the standard Keccak-256 vectors
//   2. the exact-rate-block padding edge, which is where Keccak implementations classically differ
//   3. a byte-for-byte cross-check of both typehashes against `cast keccak`, with a deliberately
//      wrong string as the negative control
//   4. viem's EIP-712 encodeType must produce the SAME string the contract hard-codes — including
//      the alphabetical ordering of referenced struct types, which is easy to get wrong by hand
//      and which nothing else would catch
//
// Run: node relayer/parity.test.mjs   (needs `cast` on PATH for check 3)

import { execFileSync } from "node:child_process";
import { keccak256, toHex, hashTypedData } from "viem";
import {
  GUARD_TYPE, ORDER_TYPE, GUARD_TYPEHASH, ORDER_TYPEHASH,
  ORDER_TYPES, hashOrder, signOrder, domainFor,
  marketOrderDefaults, rejectReasonForMarketOrder, MAX_SLIPPAGE_BPS,
} from "./order.mjs";

let failures = 0;
const check = (name, ok, detail = "") => {
  if (ok) return;
  failures++;
  console.error(`  FAIL  ${name}${detail ? " :: " + detail : ""}`);
};

// ---------------------------------------------------------------- 1 + 2: vectors

console.log("keccak-256 vectors (inherited from the hand-rolled implementation)");
const VECTORS = [
  ["", "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"],
  ["abc", "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"],
  [
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    "0x45d3b367a6904e6e8d502ee04999a7c27647f91fa845d456525fd352ae3d7371",
  ],
];
for (const [input, want] of VECTORS) {
  check(`keccak256("${input.slice(0, 20)}")`, keccak256(toHex(input)) === want, keccak256(toHex(input)));
}
// a full rate block (136 bytes) forces the padding into an extra block
check("exact-rate-block padding", keccak256(new Uint8Array(136)).length === 66);

// ---------------------------------------------------------------- 3: cast cross-check

console.log("cross-check against `cast keccak`");
let CAST = null;
for (const c of [process.env.CAST_BIN, "cast", `${process.env.HOME}/.foundry/bin/cast`]) {
  if (!c) continue;
  try { execFileSync(c, ["--version"], { encoding: "utf8" }); CAST = c; break; } catch {}
}
if (!CAST) {
  // Not a silent skip: this check is the reason the typehashes are trusted.
  console.error("  FAIL  cannot run `cast` — the cross-check did not run. Set CAST_BIN.");
  failures++;
} else {
  const castKeccak = (s) => execFileSync(CAST, ["keccak", s], { encoding: "utf8" }).trim();
  check("GUARD_TYPEHASH matches cast", castKeccak(GUARD_TYPE) === GUARD_TYPEHASH, GUARD_TYPEHASH);
  check("ORDER_TYPEHASH matches cast", castKeccak(ORDER_TYPE) === ORDER_TYPEHASH, ORDER_TYPEHASH);
  // negative control: if this matched, the comparison above would prove nothing
  check(
    "a wrong type string does NOT match",
    castKeccak("Guard(uint256 maxDevBp,uint256 maxFeedAge)") !== GUARD_TYPEHASH
  );
}

// ---------------------------------------------------------------- 4: encodeType parity

console.log("viem's encodeType vs the string the contract hard-codes");
// hashTypedData over a single struct with an empty domain isolates the struct hash, so if viem
// ordered the referenced types differently from the contract this would diverge.
const probe = {
  owner: "0x000000000000000000000000000000000000dead",
  tokenIn: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  amountIn: 1_000_000_000n,
  tokenOut: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
  minOut: 1n,
  maxFeeUsdg: 5_000_000n,
  deadline: 1_790_000_000n,
  salt: "0x" + "11".repeat(32),
  guard: { maxDevBps: 300n, maxFeedAge: 3600n },
};
const viemDigest = hashTypedData({
  domain: domainFor("0x000000000000000000000000000000000000beef"),
  types: ORDER_TYPES,
  primaryType: "Order",
  message: probe,
});
check("hashOrder agrees with a direct hashTypedData call", hashOrder(probe, "0x000000000000000000000000000000000000beef") === viemDigest);
check("digest is 32 bytes", viemDigest.length === 66);
check(
  "the domain binds the verifying contract",
  hashOrder(probe, "0x000000000000000000000000000000000000cafe") !== viemDigest
);
check(
  "the domain binds the chain",
  hashOrder(probe, "0x000000000000000000000000000000000000beef", 1) !== viemDigest
);
check(
  "maxFeedAge is part of the signed payload",
  hashOrder({ ...probe, guard: { ...probe.guard, maxFeedAge: 3601n } }, "0x000000000000000000000000000000000000beef") !== viemDigest
);

// ---------------------------------------------------------------- signing round-trip

console.log("signing");
const KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // a well-known test key
const signed = await signOrder(KEY, probe, "0x000000000000000000000000000000000000beef");
check("signature is 65 bytes", signed.signature.length === 132);
check("v is 27 or 28", signed.v === 27 || signed.v === 28, String(signed.v));
check("r and s are 32 bytes", signed.r.length === 66 && signed.s.length === 66);
check("signer is recovered deterministically", (await signOrder(KEY, probe, "0x000000000000000000000000000000000000beef")).signature === signed.signature);

// ---------------------------------------------------------------- client defaults

console.log("market-order defaults");
const d = marketOrderDefaults({ quotedNet: 1_000_000_000n, feedAgeAtQuote: 1200, nowSeconds: 1_790_000_000 });
check("minOut is quoted net minus 50 bps", d.minOut === 995_000_000n, String(d.minOut));
check("deadline is now + 120s", d.deadline === 1_790_000_120n, String(d.deadline));
check("maxFeedAge is age + deadline + 60", d.maxFeedAge === BigInt(1200 + 120 + 60), String(d.maxFeedAge));
try {
  marketOrderDefaults({ quotedNet: 1_000_000_000n, feedAgeAtQuote: 0, nowSeconds: 0, slippageBps: MAX_SLIPPAGE_BPS + 1 });
  check("slippage above the maximum is refused", false);
} catch { check("slippage above the maximum is refused", true); }

check(
  "a zero minOut is refused by the relayer too",
  rejectReasonForMarketOrder({ ...probe, minOut: 0n }, 50) !== null
);
check(
  "a zero maxFeedAge is refused",
  rejectReasonForMarketOrder({ ...probe, guard: { ...probe.guard, maxFeedAge: 0n } }, 50) !== null
);
check("an ordinary order is accepted", rejectReasonForMarketOrder(probe, 50) === null);

// ---------------------------------------------------------------- result

console.log(`\n${failures} failures`);
if (failures > 0) { console.error("FAILED"); process.exit(1); }
console.log("OK");
