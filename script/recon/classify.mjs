// G2(a): classify every scanned address before any of it becomes a headline.
//
// Transfer logs contain pools, routers, vaults, Rialto pairs and aggregator executors. Contracts
// hold zero ETH by construction, so counting them as "wallets with no gas" inflates the number.
// Three classes:
//   plain EOA  - eth_getCode returns 0x
//   7702 EOA   - code begins 0xef0100 followed by the delegate address (EIP-7702 delegation)
//   contract   - anything else
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://robinhood-rpc.publicnode.com";
const raw = JSON.parse(fs.readFileSync(new URL("./holders-raw.json", import.meta.url)));
const ethMap = JSON.parse(fs.readFileSync(new URL("./holders-eth.json", import.meta.url))).eth;
const GAS = BigInt(process.env.GAS_WEI || 11370000000000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let id = 0;

async function batch(reqs, retries = 5) {
  const body = reqs.map((r) => ({ jsonrpc: "2.0", id: ++id, method: r.method, params: r.params, _k: r.k }));
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1500 * 2 ** (i - 1));
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body.map(({ _k, ...rest }) => rest)), signal: AbortSignal.timeout(60000) }).catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!Array.isArray(j)) continue;
    const m = new Map(j.map((x) => [x.id, x]));
    return body.map((b) => { const res = m.get(b.id); return { k: b._k, v: res && !res.error ? res.result : null }; });
  }
  return reqs.map((r) => ({ k: r.k, v: null }));
}

(async () => {
  const addrs = raw.addresses;
  const cls = new Map();
  const delegates = new Map();
  let unread = 0;

  for (let i = 0; i < addrs.length; i += 30) {
    const slice = addrs.slice(i, i + 30);
    for (const { k, v } of await batch(slice.map((a) => ({ k: a, method: "eth_getCode", params: [a, "latest"] })))) {
      if (v === null) { unread++; cls.set(k, "unread"); continue; }
      if (v === "0x") { cls.set(k, "eoa"); continue; }
      if (v.toLowerCase().startsWith("0xef0100") && v.length === 48) {
        const d = "0x" + v.slice(8, 48);
        cls.set(k, "eoa7702");
        delegates.set(d, (delegates.get(d) || 0) + 1);
        continue;
      }
      cls.set(k, "contract");
    }
    if (i % 3000 === 0) process.stderr.write(`\r  code ${i}/${addrs.length}   `);
    await sleep(250);
  }
  process.stderr.write(`\r  code ${addrs.length}/${addrs.length}   \n`);

  const rows = addrs.map((a) => ({ a, cls: cls.get(a), eth: BigInt(ethMap[a] ?? "0") }));
  const by = (c) => rows.filter((r) => r.cls === c);
  const tally = (arr) => ({
    n: arr.length,
    zeroEth: arr.filter((r) => r.eth === 0n).length,
    belowGas: arr.filter((r) => r.eth < GAS).length,
  });

  const out = {
    at: new Date().toISOString(), window: raw.window, head: raw.head, gasThresholdWei: GAS.toString(),
    unreadable: unread,
    classes: { eoa: tally(by("eoa")), eoa7702: tally(by("eoa7702")), contract: tally(by("contract")) },
    topDelegates: [...delegates.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5)
      .map(([addr, count]) => ({ addr, count })),
    cls: Object.fromEntries(rows.map((r) => [r.a, r.cls])),
  };
  fs.writeFileSync(new URL("./holders-class.json", import.meta.url), JSON.stringify(out));

  const P = (x, n) => n ? (100 * x / n).toFixed(1) + "%" : "-";
  console.log("\nclass        addresses   zero ETH        below one swap");
  for (const [name, t] of Object.entries(out.classes)) {
    console.log(name.padEnd(12) + String(t.n).padStart(9) + "   " +
      (String(t.zeroEth) + " (" + P(t.zeroEth, t.n) + ")").padStart(15) + "   " +
      (String(t.belowGas) + " (" + P(t.belowGas, t.n) + ")").padStart(15));
  }
  console.log(`unreadable: ${unread}`);
  console.log("\ntop EIP-7702 delegates:");
  if (!out.topDelegates.length) console.log("  (none — no 7702 delegation seen in this set)");
  for (const d of out.topDelegates) console.log("  " + d.addr + "  " + d.count + " EOAs");
})();
