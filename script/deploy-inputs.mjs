// Generate every constructor input for the v2 deployment, verified on-chain, in ONE file.
//
// The router's venue root, its token->feed map and GaslessEntry's aggregator allowlist are all
// immutable. Each was previously something a human would have copied out of a terminal into a
// deploy command, which is exactly how the v1 deploy registered a venue with token0/token1
// inverted. This script writes them to deploy/v2-inputs.json, DeployV2.s.sol reads that file, and
// the relayer reads relayer/venues.json - the same leaves, the same proofs.
//
// Every venue is checked against the chain before it can enter the root:
//   v3     code exists; token0()/token1() read from the POOL equal the registry's (the v1 bug)
//   v4     poolId recomputed from the key equals the registry's; StateView says it is initialised
//   maker  code exists; token0()/token1() read from the PAIR equal the registry's
// A venue that fails is dropped and named, and a token-order mismatch on a pool is fatal: it means
// the registry itself is wrong and nothing downstream of it can be trusted without a look.
//
// Run: node script/deploy-inputs.mjs     (after predeploy-bindings.mjs --out deploy/bindings.json)

import fs from "node:fs";
import { keccak256, encodeAbiParameters, toFunctionSelector, getAddress } from "viem";
import { candidateVenues, leafOf, buildTree, verifyProof } from "../relayer/venues.mjs";

const RPC = process.env.PARTITIO_RPC || "https://robinhood-rpc.publicnode.com";
const POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951";
const STATE_VIEW = "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
// Kyber MetaAggregationRouterV2 - 13,724 bytes on 4663, no EIP-1967 implementation slot.
// LI.FI's diamond has NO code at its canonical address on this chain; 0x refuses stock tokens as an
// asset class. An allowlisted address that cannot route stocks is surface without purpose.
const AGGREGATORS = [
  "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5",
  "0x0000000000000000000000000000000000000000",
  "0x0000000000000000000000000000000000000000",
  "0x0000000000000000000000000000000000000000",
];

const SEL = {
  token0: toFunctionSelector("token0()"),
  token1: toFunctionSelector("token1()"),
  getSlot0: toFunctionSelector("getSlot0(bytes32)"),
};
const lower = (a) => String(a).toLowerCase();

let rpcId = 0;
async function rpc(calls) {
  // 20 per batch against publicnode (it serves state reads at 30); every item must come back.
  const out = [];
  for (let i = 0; i < calls.length; i += 20) {
    const slice = calls.slice(i, i + 20);
    const body = slice.map((c) => ({ jsonrpc: "2.0", id: ++rpcId, method: c.method, params: c.params }));
    let got = null;
    for (let a = 0; a < 5 && !got; a++) {
      if (a) await new Promise((r) => setTimeout(r, 1000 * a));
      try {
        const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
          body: JSON.stringify(body), signal: AbortSignal.timeout(30000) });
        const j = await r.json();
        if (Array.isArray(j) && j.length === body.length && j.every((x) => !x.error || !/limit/i.test(x.error.message || ""))) got = j;
      } catch { /* retry */ }
    }
    if (!got) throw new Error(`RPC batch failed after retries at offset ${i} - refusing to build a root from a partial read`);
    const byId = new Map(got.map((x) => [x.id, x]));
    for (const b of body) out.push(byId.get(b.id)?.result ?? null);
  }
  return out;
}
const call = (to, data) => ({ method: "eth_call", params: [{ to, data }, "latest"] });
const code = (a) => ({ method: "eth_getCode", params: [a, "latest"] });
const addrWord = (w) => (w && w.length >= 66 ? "0x" + w.slice(-40) : null);

const poolIdOf = (v) => keccak256(encodeAbiParameters(
  [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
  [getAddress(v.token0), getAddress(v.token1), Number(v.fee), Number(v.tickSpacing), getAddress(v.hooks)]
));

const cands = candidateVenues();
const drop = [];
const fatal = [];

// ---- v3 and makers: code + token order from the contract itself
const direct = cands.filter((v) => v.kind === "v3" || v.kind === "maker");
const dres = await rpc(direct.flatMap((v) => [code(v.target), call(v.target, SEL.token0), call(v.target, SEL.token1)]));
direct.forEach((v, i) => {
  const [c, t0, t1] = dres.slice(i * 3, i * 3 + 3);
  if (!c || c === "0x") { drop.push(`${v.kind} ${v.id} ${v.ticker}: no code`); v.bad = true; return; }
  const a0 = addrWord(t0), a1 = addrWord(t1);
  if (!a0 || !a1) { drop.push(`${v.kind} ${v.id} ${v.ticker}: token0/token1 unreadable`); v.bad = true; return; }
  if (lower(a0) !== lower(v.token0) || lower(a1) !== lower(v.token1)) {
    fatal.push(`${v.kind} ${v.id} ${v.ticker}: registry says (${v.token0}, ${v.token1}), contract says (${a0}, ${a1})`);
    v.bad = true;
  }
});

// ---- v4: the id must be the hash of the key, and the pool must be initialised
const v4 = cands.filter((v) => v.kind === "v4");
for (const v of v4) {
  const id = poolIdOf(v);
  if (lower(id) !== lower(v.poolId)) {
    fatal.push(`v4 ${v.ticker}: poolId ${v.poolId} is not the hash of its own key (${id})`);
    v.bad = true;
  }
}
const s0 = await rpc(v4.map((v) => call(STATE_VIEW, SEL.getSlot0 + v.poolId.slice(2))));
v4.forEach((v, i) => {
  if (v.bad) return;
  const r = s0[i];
  if (!r || r.length < 66 || BigInt("0x" + r.slice(2, 66)) === 0n) {
    drop.push(`v4 ${v.poolId} ${v.ticker}: not initialised (sqrtPriceX96 == 0)`);
    v.bad = true;
  }
});

if (fatal.length) {
  console.error("FATAL - the registry disagrees with the chain. Nothing is written:");
  for (const f of fatal) console.error("  " + f);
  process.exit(2);
}

const venues = cands.filter((v) => !v.bad);
const leaves = venues.map(leafOf);
const { root, proofs } = buildTree(leaves);

// every proof must verify with the same arithmetic the contract uses
let maxProof = 0;
venues.forEach((v, i) => {
  v.leaf = leaves[i];
  v.proof = proofs.get(leaves[i]);
  if (!verifyProof(v.proof, v.leaf, root)) throw new Error(`proof for ${v.id} does not verify`);
  maxProof = Math.max(maxProof, v.proof.length);
});

const bindings = JSON.parse(fs.readFileSync("deploy/bindings.json", "utf8"));
const block = Number(BigInt((await rpc([{ method: "eth_blockNumber", params: [] }]))[0]));

const venuesOut = venues.map((v) => ({
  id: v.id, ticker: v.ticker, kind: v.kind, kindNum: v.kindNum, family: v.family,
  target: v.target, token0: v.token0, token1: v.token1, fee: Number(v.fee), tickSpacing: Number(v.tickSpacing),
  hooks: v.hooks, ...(v.poolId ? { poolId: v.poolId } : {}), ...(v.poolFee ? { poolFee: v.poolFee } : {}),
  leaf: v.leaf, proof: v.proof,
}));

fs.mkdirSync("deploy", { recursive: true });
fs.writeFileSync("relayer/venues.json", JSON.stringify({
  note: "GENERATED by script/deploy-inputs.mjs - the exact leaf set of the deployed router's VENUE_ROOT. Never edit by hand; never regenerate after deployment.",
  generatedAt: new Date().toISOString(), block, root, count: venuesOut.length, venues: venuesOut,
}, null, 1) + "\n");

fs.writeFileSync("deploy/v2-inputs.json", JSON.stringify({
  chainId: 4663,
  generatedAt: new Date().toISOString(),
  block,
  poolManager: POOL_MANAGER,
  usdg: USDG,
  venueRoot: root,
  venueCount: venuesOut.length,
  stockTokens: bindings.stockTokens.map((a) => getAddress(a)),
  feeds: bindings.feeds.map((a) => getAddress(a)),
  aggregators: AGGREGATORS,
}, null, 1) + "\n");

const byKind = (k) => venues.filter((v) => v.kind === k).length;
console.log(`candidates ${cands.length}  committed ${venues.length}  (v3 ${byKind("v3")}, v4 ${byKind("v4")}, maker ${byKind("maker")})`);
console.log(`tickers with a committed venue: ${new Set(venues.map((v) => v.ticker)).size}`);
console.log(`root ${root}   deepest proof ${maxProof}`);
if (drop.length) { console.log(`dropped ${drop.length}:`); for (const d of drop) console.log("  " + d); }
console.log("wrote relayer/venues.json and deploy/v2-inputs.json");
