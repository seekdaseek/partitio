// G1 addendum: prove EIP-2612 permit on each stock token by DOING it.
//
// permit() is state-changing, so a bare eth_call proves only that the selector exists. Multicall3
// lets permit() and allowance() run inside ONE eth_call, where the state change persists: if the
// allowance reads back equal to the permitted value, the domain separator, typehash and digest
// are all correct. Same standard as the USDG receiveWithAuthorization dry-run.
import { execFileSync } from "node:child_process";
import fs from "node:fs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const CAST = `${process.env.HOME}/.foundry/bin/cast`;
const MC3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
const OWNER = "0x7a7c915D8dA490c48915Fe735DDf41f8Dea83dC2";
const SPENDER = "0x732F703bAFB5B4375985cbfa9C37F3AEe3A03cbB";   // the deployed router
const VALUE = 123456789n;
const DEADLINE = 4102444800n;                                    // 2100-01-01
const PERMIT_TYPEHASH = "0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9";

const TOKENS = {
  AAPL: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
  TSLA: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d",
  NVDA: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
  SPY:  "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C",
  QQQ:  "0xd5f3879160bc7c32ebb4dC785F8a4F505888de68",
};

const pad = (h) => String(h).replace(/^0x/, "").toLowerCase().padStart(64, "0");
const padInt = (n) => pad(BigInt(n).toString(16));
const cast = (...a) => execFileSync(CAST, a, { encoding: "utf8" }).trim();
let id = 0;
async function call(to, data) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "eth_call", params: [{ to, data }, "latest"] }) });
  const j = await r.json();
  return j.error ? { err: j.error.message } : { ok: j.result };
}

// aggregate3((address target, bool allowFailure, bytes callData)[])
function encodeAggregate3(calls) {
  const n = calls.length;
  const offsets = [];
  const tails = [];
  let cur = n * 32;
  for (const c of calls) {
    offsets.push(cur);
    const cd = c.data.replace(/^0x/, "");
    const words = Math.ceil(cd.length / 64);
    const tail = pad(c.target) + padInt(c.allowFailure ? 1 : 0) + padInt(0x60)
      + padInt(cd.length / 2) + cd.padEnd(words * 64, "0");
    tails.push(tail);
    cur += tail.length / 2;
  }
  return "0x82ad56cb" + padInt(0x20) + padInt(n) + offsets.map(padInt).join("") + tails.join("");
}

function decodeAggregate3(ret, n) {
  const d = ret.replace(/^0x/, "");
  const arrOff = parseInt(d.slice(0, 64), 16) * 2;
  const count = parseInt(d.slice(arrOff, arrOff + 64), 16);
  const base = arrOff + 64;
  const out = [];
  for (let i = 0; i < Math.min(count, n); i++) {
    const off = parseInt(d.slice(base + i * 64, base + (i + 1) * 64), 16) * 2;
    const s = base + off;
    const success = parseInt(d.slice(s, s + 64), 16) === 1;
    const rdOff = parseInt(d.slice(s + 64, s + 128), 16) * 2;
    const rs = s + rdOff;
    const rdLen = parseInt(d.slice(rs, rs + 64), 16);
    out.push({ success, data: "0x" + d.slice(rs + 64, rs + 64 + rdLen * 2) });
  }
  return out;
}

(async () => {
  const pk = JSON.parse(fs.readFileSync(process.env.HOME + "/.config/partitio/deployer.json", "utf8")).data[0].private_key;
  const results = [];
  console.log("token  domainSeparator          nonce  permit  allowance == value   verdict");
  for (const [sym, addr] of Object.entries(TOKENS)) {
    const ds = (await call(addr, "0x3644e515")).ok;
    const nr = (await call(addr, "0x7ecebe00" + pad(OWNER))).ok;
    if (!ds || !nr) { console.log(`${sym}  READ FAILED`); continue; }
    const nonce = BigInt(nr);

    const structHash = cast("keccak", cast("abi-encode",
      "f(bytes32,address,address,uint256,uint256,uint256)",
      PERMIT_TYPEHASH, OWNER, SPENDER, VALUE.toString(), nonce.toString(), DEADLINE.toString()));
    const digest = cast("keccak", "0x1901" + ds.replace(/^0x/, "") + structHash.replace(/^0x/, ""));
    const sig = cast("wallet", "sign", "--no-hash", digest, "--private-key", pk);
    const r = "0x" + sig.slice(2, 66), s = "0x" + sig.slice(66, 130), v = parseInt(sig.slice(130, 132), 16);

    const permitCd = "0xd505accf" + pad(OWNER) + pad(SPENDER) + padInt(VALUE) + padInt(DEADLINE)
      + padInt(v) + pad(r) + pad(s);
    const allowCd = "0xdd62ed3e" + pad(OWNER) + pad(SPENDER);

    const data = encodeAggregate3([
      { target: addr, allowFailure: true, data: permitCd },
      { target: addr, allowFailure: true, data: allowCd },
    ]);
    const res = await call(MC3, data);
    if (res.err) { console.log(`${sym}  aggregate3 ERR ${res.err.slice(0, 50)}`); continue; }
    const [p, a] = decodeAggregate3(res.ok, 2);
    const allowance = a.success && a.data.length >= 66 ? BigInt(a.data.slice(0, 66)) : null;
    const pass = p.success && allowance === VALUE;
    results.push({ sym, permitOk: p.success, allowance: allowance?.toString() ?? null, pass });
    console.log(
      sym.padEnd(6) + ds.slice(0, 22) + "  " + String(nonce).padStart(5) + "  " +
      (p.success ? "  ok  " : " FAIL ") + "  " + String(allowance).padStart(12) + " / " + VALUE +
      "   " + (pass ? "PASS" : "FAIL"));
  }
  console.log();
  console.log(`${results.filter((r) => r.pass).length}/${results.length} tokens proved permit end-to-end`);
})();
