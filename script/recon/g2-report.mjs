// G2 report: how many wallets hold a position they cannot afford to move?
//
// The threshold is one approve + one swap at the live gas price. On 4663 that is a very small
// number, so this is deliberately not a story about expensive gas — it is a story about wallets
// holding ZERO or dust ETH, which on a chain where the only gas asset is ETH means the position
// is immobile until someone sends them gas.
import fs from "node:fs";

const B = JSON.parse(fs.readFileSync(new URL("./holders-balances.json", import.meta.url)));
const GAS_APPROVE_SWAP = Number(process.env.GAS_WEI || 11370000000000); // 270k * 0.0421 gwei
const MIN_USD = 10;

const usdOf = (row) => {
  let usd = 0;
  for (const [sym, v] of Object.entries(row.bal)) {
    if (sym === "USDG") { usd += Number(v) / 1e6; continue; }
    const px = B.prices[sym];
    if (!px) continue;
    usd += (Number(v) / 1e18) * px;
  }
  return usd;
};

const rows = B.rows.map((r) => ({ ...r, usd: usdOf(r), ethWei: Number(r.eth) }));
const held = rows.filter((r) => r.usd >= MIN_USD);
const stuck = held.filter((r) => r.ethWei < GAS_APPROVE_SWAP);
const zeroEth = held.filter((r) => r.ethWei === 0);

const sum = (a) => a.reduce((x, r) => x + r.usd, 0);
const fmt = (n) => n.toLocaleString(undefined, { maximumFractionDigits: 0 });

console.log("=== G2 — wallets that cannot move their own position ===");
console.log();
console.log(`scan window        : ${fmt(B.window)} blocks ending ${B.head}`);
console.log(`addresses examined : ${fmt(B.addresses)}`);
console.log(`tokens priced      : ${Object.values(B.prices).filter(Boolean).length} of ${Object.keys(B.prices).length} (+ USDG)`);
console.log(`gas threshold      : ${GAS_APPROVE_SWAP / 1e18} ETH (approve + one swap)`);
console.log();
console.log(`addresses with any balance      : ${fmt(rows.length)}`);
console.log(`holding >= $${MIN_USD}                 : ${fmt(held.length)}   ($${fmt(sum(held))})`);
console.log(`  of those, ETH below threshold : ${fmt(stuck.length)}   ($${fmt(sum(stuck))})`);
console.log(`  of those, ETH exactly ZERO    : ${fmt(zeroEth.length)}   ($${fmt(sum(zeroEth))})`);
console.log();
const pct = held.length ? (100 * stuck.length / held.length).toFixed(1) : "0";
console.log(`=> ${pct}% of wallets holding >= $${MIN_USD} cannot pay for one swap.`);
console.log();

// distribution of the stuck cohort
const buckets = [[10, 100], [100, 1000], [1000, 10000], [10000, 1e9]];
console.log("stuck cohort by size:");
for (const [lo, hi] of buckets) {
  const b = stuck.filter((r) => r.usd >= lo && r.usd < hi);
  if (!b.length) continue;
  console.log(`  $${fmt(lo)}-${hi >= 1e9 ? "+" : "$" + fmt(hi)}`.padEnd(22) + `${fmt(b.length)} wallets   $${fmt(sum(b))}`);
}
console.log();
console.log("largest stuck holdings:");
for (const r of [...stuck].sort((a, b) => b.usd - a.usd).slice(0, 8)) {
  const top = Object.entries(r.bal).map(([s, v]) => s).slice(0, 4).join(",");
  console.log(`  ${r.a}  $${fmt(r.usd).padStart(10)}  eth ${r.ethWei}  [${top}]`);
}
console.log();
console.log("CAVEATS");
console.log(" - bounded window, and 40 of 370 log pages failed to rate limits, so this UNDERCOUNTS.");
console.log(" - recently-active wallets are over-represented and they are MORE likely to hold ETH,");
console.log("   so the true immobile population is at least this large.");
console.log(" - unpriced tokens contribute $0 to a wallet's value, which also undercounts.");
