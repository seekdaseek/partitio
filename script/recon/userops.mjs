// Point 1: are these 7702 wallets sponsored for everything, sponsored for one app's flows, or
// self-paying? The paymaster field of UserOperationEvent answers it: 0x0 means the sender paid
// its own gas, anything else is a sponsor.
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const T_UOE = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f";
const ENTRYPOINTS = {
  "canonical v0.7": "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  "canonical v0.8": "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108",
};
const WINDOW = Number(process.env.UOP_WINDOW || 100000);   // ~2.8h at 0.1008s blocks
const PAGE = Number(process.env.UOP_PAGE || 10000);
const ZERO = "0x0000000000000000000000000000000000000000";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let id = 0;

async function rpc(method, params, retries = 5) {
  for (let i = 0; i <= retries; i++) {
    if (i) await sleep(1500 * 2 ** (i - 1));
    const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }), signal: AbortSignal.timeout(60000) }).catch(() => null);
    if (!r || r.status === 429) continue;
    const j = await r.json().catch(() => null);
    if (!j) continue;
    if (j.error) {
      if (/Too Many Requests|timed out/i.test(j.error.message || "")) continue;
      return { err: j.error.message };
    }
    return { ok: j.result };
  }
  return { err: "retries exhausted" };
}

(async () => {
  const head = parseInt((await rpc("eth_blockNumber", [])).ok, 16);
  const from = head - WINDOW;
  console.log(`window ${from}..${head} (${WINDOW} blocks ~ ${(WINDOW * 0.1008 / 3600).toFixed(2)}h)\n`);

  const cls = JSON.parse(fs.readFileSync(new URL("./holders-class.json", import.meta.url))).cls;
  const is7702 = (a) => cls[a] === "eoa7702";

  const report = {};
  for (const [name, ep] of Object.entries(ENTRYPOINTS)) {
    const paymasters = new Map();
    const senders = new Map();
    let n = 0, failed = 0, selfPaid = 0;
    for (let b = from; b < head; b += PAGE) {
      const to = Math.min(b + PAGE - 1, head);
      const r = await rpc("eth_getLogs", [{ fromBlock: "0x" + b.toString(16), toBlock: "0x" + to.toString(16),
        address: ep, topics: [T_UOE] }]);
      if (r.err) { failed++; await sleep(600); continue; }
      for (const l of r.ok) {
        n++;
        const sender = "0x" + l.topics[2].slice(26);
        const pm = "0x" + l.topics[3].slice(26);
        if (pm === ZERO) selfPaid++;
        paymasters.set(pm, (paymasters.get(pm) || 0) + 1);
        senders.set(sender, (senders.get(sender) || 0) + 1);
      }
      await sleep(500);
    }
    const top = [...paymasters.entries()].sort((a, b) => b[1] - a[1]);
    const sendersIn7702 = [...senders.keys()].filter(is7702).length;
    report[name] = { ep, userOps: n, failedPages: failed, selfPaid,
      sponsored: n - selfPaid, distinctSenders: senders.size, sendersIn7702Set: sendersIn7702,
      paymasters: top.slice(0, 6).map(([a, c]) => ({ a, c, pct: n ? +(100 * c / n).toFixed(1) : 0 })) };

    console.log(`${name}  (${ep})`);
    console.log(`  userOps ${n}   failed pages ${failed}`);
    if (n) {
      console.log(`  SELF-PAID (paymaster 0x0) : ${selfPaid}  (${(100 * selfPaid / n).toFixed(1)}%)`);
      console.log(`  SPONSORED                 : ${n - selfPaid}  (${(100 * (n - selfPaid) / n).toFixed(1)}%)`);
      console.log(`  distinct senders          : ${senders.size}  (${sendersIn7702} are in our 7702 set)`);
      console.log(`  paymasters:`);
      for (const p of top.slice(0, 6))
        console.log(`    ${p[0]}  ${String(p[1]).padStart(6)}  ${(100 * p[1] / n).toFixed(1)}%${p[0] === ZERO ? "   <- self-paid" : ""}`);
    }
    console.log();
  }
  fs.writeFileSync(new URL("./userops.json", import.meta.url), JSON.stringify({ at: new Date().toISOString(), head, window: WINDOW, report }, null, 1));
  console.log("wrote script/recon/userops.json");
})();
