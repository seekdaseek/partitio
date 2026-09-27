// The committed venue set: ONE module that produces both the router's immutable VENUE_ROOT and the
// Merkle proof the relayer attaches to every leg.
//
// Why one module. The root is fixed forever at deployment, and every leg the relayer sends must
// prove membership in it. If the deploy script and the relayer each derived the venue list on their
// own, the first disagreement would surface on mainnet as BadVenueProof — after the immutable
// deploy, with no way to add the missing leaf. So the deploy input is generated FROM this module
// (script/deploy-inputs.mjs), and the relayer reads the same file back.
//
// What gets committed, and why it is a filter rather than "everything in the registry":
//   - quoted against USDG, for a stock that has a bound feed and is not HIDDEN. The guard prices a
//     stock against a USD stable; a WETH-quoted venue would give it a reference in the wrong unit,
//     so the only safe way to keep that pair unreachable is to never commit it.
//   - v3: every USDG pool in the registry.
//   - v4: hookless, static fee, fee <= 1%, non-zero liquidity. The registry holds hundreds of v4
//     pools charging 77-99% fees. A venue in the root is a venue ANY filler may route through, and
//     a filler who owns the LP position in a 90%-fee pool is paid by routing a sliver of someone
//     else's order into it. The oracle floor and minOut bound that loss; not committing the pool
//     removes it.
//   - makers: only pairs whose settlement was proven on a fork. An unproven pair in an immutable
//     root is a liability with no demonstrated upside.
//
// The tree is the sorted-pair construction PartitioRouterV2._verify checks: leaf =
// keccak256(keccak256(abi.encode(venue))), parent = keccak256(sort(a, b)), an odd node is carried
// up unhashed. Leaves are sorted by value, so the root depends only on the SET of venues.

import fs from "node:fs";
import path from "node:path";
import { keccak256, encodeAbiParameters, concat, getAddress } from "viem";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const readJson = (f) => JSON.parse(fs.readFileSync(path.join(HERE, f), "utf8"));

export const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
export const HIDDEN = new Set(["GLD", "RDDT"]);
export const V4_MAX_FEE = 10_000; // 1.00%, in v4 fee pips

export const KIND = { V3: 0, V4: 1, MAKER: 2 };

const VENUE_TUPLE = [{
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" },
    { name: "target", type: "address" },
    { name: "token0", type: "address" },
    { name: "token1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
}];

const ZERO = "0x0000000000000000000000000000000000000000";
const lower = (a) => String(a).toLowerCase();

/** The exact struct PartitioRouterV2 hashes, with checksummed addresses. */
export function structOf(v) {
  return {
    kind: v.kindNum,
    target: getAddress(v.target),
    token0: getAddress(v.token0),
    token1: getAddress(v.token1),
    fee: Number(v.fee),
    tickSpacing: Number(v.tickSpacing),
    hooks: getAddress(v.hooks),
  };
}

export function leafOf(v) {
  return keccak256(concat([keccak256(encodeAbiParameters(VENUE_TUPLE, [structOf(v)]))]));
}

const hashPair = (a, b) => (BigInt(a) <= BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a])));

/** Sorted-pair tree. Returns the root and, for every leaf, its proof. */
export function buildTree(leaves) {
  if (leaves.length === 0) throw new Error("empty venue set");
  const sorted = [...new Set(leaves)].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1));
  if (sorted.length !== leaves.length) throw new Error("duplicate leaf: two venues hash identically");
  const proofs = new Map(sorted.map((l) => [l, []]));
  // track which original leaves sit under each node of the current level
  let level = sorted.map((l) => ({ h: l, under: [l] }));
  while (level.length > 1) {
    const next = [];
    for (let i = 0; i < level.length; i += 2) {
      const a = level[i];
      const b = level[i + 1];
      if (!b) { next.push(a); continue; }            // odd node carried up, no proof element
      for (const l of a.under) proofs.get(l).push(b.h);
      for (const l of b.under) proofs.get(l).push(a.h);
      next.push({ h: hashPair(a.h, b.h), under: [...a.under, ...b.under] });
    }
    level = next;
  }
  return { root: level[0].h, proofs };
}

/** Mirror of PartitioRouterV2._verify, so a bad proof is caught here and not on-chain. */
export function verifyProof(proof, leaf, root) {
  let h = leaf;
  for (const p of proof) h = hashPair(h, p);
  return lower(h) === lower(root);
}

/**
 * The venues to commit, from the registry snapshot. Deterministic: same files in, same set out.
 * `id` is what the quote engine calls a venue (pool address, v4 poolId, maker address).
 */
export function candidateVenues({
  registry = readJson("registry.json"),
  makers = readJson("makers.json"),
  feeds = readJson("chainlink-feeds.json").feeds,
} = {}) {
  const bound = (t) => Boolean(feeds[t]) && !HIDDEN.has(t);
  const out = [];

  for (const e of registry.v3) {
    if (e.quote !== "USDG" || !bound(e.ticker)) continue;
    out.push({
      id: lower(e.addr), ticker: e.ticker, kind: "v3", kindNum: KIND.V3, family: e.family,
      target: e.addr, token0: e.token0, token1: e.token1, fee: 0, tickSpacing: 0, hooks: ZERO,
      poolFee: e.fee, liquidity: e.liquidity,
    });
  }
  for (const e of registry.v4) {
    if (e.quote !== "USDG" || !bound(e.ticker)) continue;
    if (BigInt(e.hooks) !== 0n || e.dynamicFee || Number(e.fee) > V4_MAX_FEE) continue;
    if (BigInt(e.liquidity || 0) === 0n) continue;
    out.push({
      id: lower(e.poolId), ticker: e.ticker, kind: "v4", kindNum: KIND.V4, family: "uniswap-v4",
      target: ZERO, token0: e.currency0, token1: e.currency1, fee: e.fee, tickSpacing: e.tickSpacing,
      hooks: e.hooks, poolId: e.poolId, liquidity: e.liquidity,
    });
  }
  for (const [ticker, pairs] of Object.entries(makers)) {
    if (!bound(ticker)) continue;
    for (const p of pairs) {
      if (!p.settlementProven) continue;
      out.push({
        id: lower(p.addr), ticker, kind: "maker", kindNum: KIND.MAKER, family: p.family || "fermi-prop",
        target: p.addr, token0: p.token0, token1: p.token1, fee: 0, tickSpacing: 0, hooks: ZERO,
      });
    }
  }
  // every committed venue must be exactly {USDG, stock}
  for (const v of out) {
    const pair = [lower(v.token0), lower(v.token1)];
    if (!pair.includes(lower(USDG))) throw new Error(`${v.kind} ${v.id} (${v.ticker}) is not USDG-quoted`);
    if (pair[0] === pair[1]) throw new Error(`${v.id}: token0 == token1`);
  }
  return out;
}

// ---------------------------------------------------------------- the committed set, as deployed

let COMMITTED = null;

/**
 * The venue set the deployed router actually commits to, read back from the generated file. The
 * relayer must never re-derive this: the registry can grow after deployment, the root cannot.
 */
export function committed() {
  if (COMMITTED) return COMMITTED;
  const f = path.join(HERE, "venues.json");
  if (!fs.existsSync(f)) return null;
  const j = JSON.parse(fs.readFileSync(f, "utf8"));
  const byId = new Map();
  for (const v of j.venues) byId.set(lower(v.id), v);
  COMMITTED = { root: j.root, byId, venues: j.venues };
  return COMMITTED;
}

/** A quote leg's venue id -> the struct and proof the contract expects, or null if uncommitted. */
export function legVenue(id) {
  const c = committed();
  if (!c) return null;
  const v = c.byId.get(lower(id));
  if (!v) return null;
  return { venueStruct: structOf(v), proof: v.proof };
}
