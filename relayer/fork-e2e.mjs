// The whole relayer -> contract path, with REAL sends, against a local anvil fork of mainnet.
//
// This is where the first transaction partitio's relayer ever broadcasts is sent - on purpose, on a
// chain that does not matter. It refuses to start unless the RPC is loopback AND the node reports
// itself as anvil, and every key it holds is one of anvil's published development keys.
//
// What it proves, in order:
//   deploy   the exact bytecode and the exact generated inputs; every immutable reads back
//   buy      1 USDG -> AAPL through committed venues with real Merkle proofs; receipt, balances,
//            allowances, `executed`, and nothing left at rest in either contract
//   sell     the AAPL straight back to USDG via EIP-2612 permit; same assertions
//   burner 1 the same order submitted twice at once: exactly one transaction
//   burner 2 two different orders from one wallet at once: exactly one transaction
//   burner 3 two wallets at once with mining paused: one serial queue, sequential nonces, the stuck
//            first transaction replaced at the SAME nonce with a higher fee, the original never mined
//   gas      per trade, from the receipts
//
// Run:  anvil --fork-url https://robinhood-rpc.publicnode.com --port 8545   (separately)
//       PARTITIO_RPC_OVERRIDE=http://127.0.0.1:8545 node relayer/fork-e2e.mjs

import fs from "node:fs";
import path from "node:path";
import {
  createPublicClient, createWalletClient, http, parseAbi, getAddress, keccak256, toHex, parseSignature,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { assertLocalAnvil, createSender } from "./sender.mjs";
import { handleOrder } from "./submit.mjs";
import { onChainQuote } from "./quote.mjs";
import { ORDER_TYPES, domainFor, normalizeOrder, hashOrder, marketOrderDefaults } from "./order.mjs";
import { call } from "./rpc.mjs";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const ROOT = path.resolve(HERE, "..");
const RPC = process.env.PARTITIO_RPC_OVERRIDE;
if (!RPC) { console.error("set PARTITIO_RPC_OVERRIDE to the local anvil URL"); process.exit(2); }

const version = await assertLocalAnvil(RPC);
console.log(`node: ${version}  (${RPC})`);

// anvil's published development keys - worthless anywhere but here
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // 0 deployer
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // 1 relayer
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // 2 user A
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // 3 user B
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a", // 4 user C
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba", // 5 user D
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e", // 6 user E
];
const acct = KEYS.map((k) => privateKeyToAccount(k));
const [DEPLOYER, RELAYER, A, B, C, D, E] = acct;

const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
const CHAIN_ID = 4663;
const chain = { id: CHAIN_ID, name: "robinhood-fork", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = (account) => createWalletClient({ chain, transport: http(RPC), account });

const ERC20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function nonces(address) view returns (uint256)",
  "function eip712Domain() view returns (bytes1,string,string,uint256,address,bytes32,uint256[])",
]);
const bal = (t, a) => pub.readContract({ address: t, abi: ERC20, functionName: "balanceOf", args: [a] });
const allow = (t, o, s) => pub.readContract({ address: t, abi: ERC20, functionName: "allowance", args: [o, s] });

let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}${detail ? "  " + detail : ""}`);
  if (!ok) failures++;
};

// ---------------------------------------------------------------- deploy

const art = (n) => JSON.parse(fs.readFileSync(path.join(ROOT, "out", `${n}.sol`, `${n}.json`), "utf8"));
const inputs = JSON.parse(fs.readFileSync(path.join(ROOT, "deploy", "v2-inputs.json"), "utf8"));
const R = art("PartitioRouterV2");
const G = art("GaslessEntry");

console.log("\ndeploy (same bytecode, same generated inputs)");
const dw = wallet(DEPLOYER);
const rHash = await dw.deployContract({ abi: R.abi, bytecode: R.bytecode.object,
  args: [inputs.poolManager, inputs.venueRoot, inputs.stockTokens, inputs.feeds] });
const rRcpt = await pub.waitForTransactionReceipt({ hash: rHash });
const ROUTER = rRcpt.contractAddress;
const eHash = await dw.deployContract({ abi: G.abi, bytecode: G.bytecode.object,
  args: [inputs.usdg, ROUTER, inputs.aggregators] });
const eRcpt = await pub.waitForTransactionReceipt({ hash: eHash });
const ENTRY = eRcpt.contractAddress;
check("router deployed", rRcpt.status === "success", `${ROUTER}  gas ${rRcpt.gasUsed}`);
check("entry deployed", eRcpt.status === "success", `${ENTRY}  gas ${eRcpt.gasUsed}`);
const root = await pub.readContract({ address: ROUTER, abi: R.abi, functionName: "VENUE_ROOT" });
check("VENUE_ROOT is the generated root", root === inputs.venueRoot);
const deployGas = { router: rRcpt.gasUsed, entry: eRcpt.gasUsed };

// ---------------------------------------------------------------- funding (fork only)

// Impersonate a pool that is NOT on the AAPL route, so the route's own balances are untouched.
const FUNDER = getAddress("0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed"); // AAPL pool B - holds USDG
await call("anvil_impersonateAccount", [FUNDER]);
await call("anvil_setBalance", [FUNDER, toHex(10n ** 18n)]);
const fw = createWalletClient({ chain, transport: http(RPC), account: FUNDER });
const funded = [];
for (const u of [A, B, C, D, E]) {
  const b0 = await bal(USDG, u.address);
  const h = await fw.writeContract({ address: USDG, abi: ERC20, functionName: "transfer", args: [u.address, 5_000_000n] });
  await pub.waitForTransactionReceipt({ hash: h });
  funded.push((await bal(USDG, u.address)) - b0);
}
await call("anvil_stopImpersonatingAccount", [FUNDER]);
for (const u of [A, B, C, D, E]) {
  // the users hold NO ETH: that is the product
  await call("anvil_setBalance", [u.address, "0x0"]);
}
check("five test wallets each received 5 USDG and hold zero ETH", funded.every((d) => d === 5_000_000n)
  && (await pub.getBalance({ address: A.address })) === 0n);

// the relayer, on its own queue, with a short receipt timeout so the replacement path can be driven
const sender = createSender({ privateKey: KEYS[1], chainId: CHAIN_ID, anvil: true, receiptTimeoutMs: 1500 });

// ---------------------------------------------------------------- order construction

const USDG_DOMAIN = { name: "Global Dollar", version: "1", chainId: CHAIN_ID, verifyingContract: USDG };
const RECEIVE_TYPES = { ReceiveWithAuthorization: [
  { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
  { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" },
] };
const PERMIT_TYPES = { Permit: [
  { name: "owner", type: "address" }, { name: "spender", type: "address" }, { name: "value", type: "uint256" },
  { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" },
] };

const salt = () => keccak256(toHex(`${Date.now()}-${Math.random()}`));
const split = (sig) => { const p = parseSignature(sig); return { v: Number(p.v ?? (p.yParity + 27)), r: p.r, s: p.s }; };

async function nowSeconds() {
  return Number((await pub.getBlock({ blockTag: "latest" })).timestamp);
}

/** Build and sign an order exactly as the app will: quote, floor from the quote, sign twice. */
async function buildOrder(user, direction, amountIn, feeBps = 40) {
  const now = await nowSeconds();
  const sell = direction === "sell";
  // buy: the fee comes off the USDG input; sell: out of the USDG output
  const fee = sell ? 0n : (amountIn * BigInt(feeBps)) / 10_000n;
  const spendable = amountIn - fee;
  const q = await onChainQuote("AAPL", direction, spendable);
  const gross = BigInt(q.partitio);
  const sellFee = sell ? (gross * BigInt(feeBps)) / 10_000n : 0n;
  const net = sell ? gross - sellFee : gross;
  const d = marketOrderDefaults({ quotedNet: net, feedAgeAtQuote: now - Number(q.oracleUpdatedAt), nowSeconds: now });
  const order = {
    owner: user.address, tokenIn: sell ? AAPL : USDG, amountIn, tokenOut: sell ? USDG : AAPL,
    minOut: d.minOut, maxFeeUsdg: sell ? sellFee : fee, deadline: d.deadline, salt: salt(),
    guard: { maxDevBps: 200n, maxFeedAge: d.maxFeedAge },
  };
  const oh = hashOrder(order, ENTRY, CHAIN_ID);
  const osig = await user.signTypedData({ domain: domainFor(ENTRY, CHAIN_ID), types: ORDER_TYPES,
    primaryType: "Order", message: normalizeOrder(order) });
  let psig;
  if (!sell) {
    psig = await user.signTypedData({ domain: USDG_DOMAIN, types: RECEIVE_TYPES, primaryType: "ReceiveWithAuthorization",
      message: { from: user.address, to: ENTRY, value: amountIn, validAfter: 0n, validBefore: order.deadline, nonce: oh } });
  } else {
    const dom = await pub.readContract({ address: AAPL, abi: ERC20, functionName: "eip712Domain" });
    const nonce = await pub.readContract({ address: AAPL, abi: ERC20, functionName: "nonces", args: [user.address] });
    psig = await user.signTypedData({ domain: { name: dom[1], version: dom[2], chainId: Number(dom[3]), verifyingContract: dom[4] },
      types: PERMIT_TYPES, primaryType: "Permit",
      message: { owner: user.address, spender: ENTRY, value: amountIn, nonce, deadline: order.deadline } });
  }
  const o = split(osig), p = split(psig);
  const auth = { signature: osig, v: o.v, r: o.r, s: o.s, pv: p.v, pr: p.r, ps: p.s,
    validAfter: 0, validBefore: order.deadline };
  return { body: { order, auth, fee: sell ? sellFee : fee, slippageBps: d.slippageBps, ticker: "AAPL", direction },
           orderHash: oh, quote: q };
}

const submit = (body) => handleOrder(body, { send: sender, entryAddress: ENTRY });
const executed = (oh) => pub.readContract({ address: ENTRY, abi: G.abi, functionName: "executed", args: [oh] });

async function atRest() {
  const [eu, ea, ru, ra] = await Promise.all([bal(USDG, ENTRY), bal(AAPL, ENTRY), bal(USDG, ROUTER), bal(AAPL, ROUTER)]);
  return eu + ea + ru + ra;
}

// ---------------------------------------------------------------- buy

console.log("\nbuy 1 USDG of AAPL (the demo trade, on the fork)");
const gasRows = [];
{
  const u0 = await bal(USDG, A.address), a0 = await bal(AAPL, A.address), rl0 = await bal(USDG, RELAYER.address);
  const { body, orderHash } = await buildOrder(A, "buy", 1_000_000n);
  const { code, out } = await submit(body);
  check("filled and mined", code === 200 && out.sent && out.ok, JSON.stringify(out).slice(0, 220));
  if (out.sent) {
    const u1 = await bal(USDG, A.address), a1 = await bal(AAPL, A.address), rl1 = await bal(USDG, RELAYER.address);
    check("user paid exactly 1 USDG", u0 - u1 === 1_000_000n, `${u0 - u1}`);
    check("user received at least minOut", a1 - a0 >= body.order.minOut, `${a1 - a0} >= ${body.order.minOut}`);
    check("relayer earned exactly the signed fee (the whole order was spent)", rl1 - rl0 === body.fee, `${rl1 - rl0}`);
    check("order marked executed", await executed(orderHash));
    check("nothing at rest in entry or router", (await atRest()) === 0n);
    check("no allowance left entry -> router", (await allow(USDG, ENTRY, ROUTER)) === 0n);
    check("user still holds zero ETH", (await pub.getBalance({ address: A.address })) === 0n);
    gasRows.push(["buy", BigInt(out.gasUsed)]);
    console.log(`        tx ${out.txHash}  gas ${out.gasUsed}`);
  }
}

// ---------------------------------------------------------------- sell back

console.log("\nsell it all back (permit, fee out of the USDG proceeds)");
{
  const held = await bal(AAPL, A.address);
  const u0 = await bal(USDG, A.address), rl0 = await bal(USDG, RELAYER.address);
  const { body, orderHash } = await buildOrder(A, "sell", held);
  const { code, out } = await submit(body);
  check("filled and mined", code === 200 && out.sent && out.ok, JSON.stringify(out).slice(0, 220));
  if (out.sent) {
    const u1 = await bal(USDG, A.address), rl1 = await bal(USDG, RELAYER.address);
    check("user holds no AAPL afterwards", (await bal(AAPL, A.address)) === 0n);
    check("user netted at least minOut", u1 - u0 >= body.order.minOut, `${u1 - u0} >= ${body.order.minOut}`);
    check("relayer fee within the signed cap", rl1 - rl0 <= body.fee && rl1 - rl0 > 0n, `${rl1 - rl0}`);
    check("order marked executed", await executed(orderHash));
    check("nothing at rest in entry or router", (await atRest()) === 0n);
    check("no allowance left user -> entry", (await allow(AAPL, A.address, ENTRY)) === 0n);
    gasRows.push(["sell", BigInt(out.gasUsed)]);
    const roundTrip = Number(1_000_000n - (u1 - u0));
    console.log(`        tx ${out.txHash}  gas ${out.gasUsed}   round trip cost ${roundTrip} micro-USDG on 1 USDG`);
  }
}

// ---------------------------------------------------------------- burner 1: same order twice

console.log("\nburner 1: the same order submitted twice at once");
{
  const { body, orderHash } = await buildOrder(B, "buy", 1_000_000n);
  const before = sender.stats.sent;
  const [r1, r2] = await Promise.all([submit(body), submit(body)]);
  const sent = [r1, r2].filter((r) => r.out.sent).length;
  const locked = [r1, r2].filter((r) => r.code === 409).length;
  check("exactly one transaction", sent === 1 && sender.stats.sent - before === 1, `sent ${sent}`);
  check("the other was refused by the order lock, not by the chain", locked === 1);
  const r3 = await submit(body);
  check("a later resubmit is refused by simulation, nothing sent", r3.code === 422 && !r3.out.sent
    && r3.out.revert?.name === "AlreadyExecuted", r3.out.revert?.name);
  check("order executed once", await executed(orderHash));
}

// ---------------------------------------------------------------- burner 2: two orders, one wallet

console.log("\nburner 2: two different orders from one wallet at once");
{
  const x = await buildOrder(C, "buy", 1_000_000n);
  const y = await buildOrder(C, "buy", 1_000_000n);
  const before = sender.stats.sent;
  const [r1, r2] = await Promise.all([submit(x.body), submit(y.body)]);
  const sent = [r1, r2].filter((r) => r.out.sent).length;
  check("exactly one transaction", sent === 1 && sender.stats.sent - before === 1, `sent ${sent}`);
  check("the other was refused by the wallet lock", [r1, r2].some((r) => r.code === 409 && /one order at a time/.test(r.out.reason)));
}

// ---------------------------------------------------------------- burner 3: queue + replacement

console.log("\nburner 3: two wallets at once, mining paused - one queue, one replacement");
{
  const x = await buildOrder(D, "buy", 1_000_000n);
  const y = await buildOrder(E, "buy", 1_000_000n);
  await call("evm_setAutomine", [false]);
  // mine once after the first transaction has had to be replaced, then resume normal mining
  const miner = new Promise((res) => setTimeout(async () => {
    await call("evm_mine", []);
    await call("evm_setAutomine", [true]);
    res();
  }, 4000));
  const [r1, r2] = await Promise.all([submit(x.body), submit(y.body)]);
  await miner;
  check("both filled", r1.out.ok && r2.out.ok, `${r1.code} ${r2.code}`);
  const first = [r1, r2].find((r) => r.out.replacements > 0);
  check("the stuck transaction was replaced at the same nonce", Boolean(first), `replacements ${r1.out.replacements}/${r2.out.replacements}`);
  if (first) {
    const originals = first.out.attempts.filter((h) => h !== first.out.txHash);
    let minedOriginals = 0;
    for (const h of originals) if (await call("eth_getTransactionReceipt", [h]).catch(() => null)) minedOriginals++;
    check("the mined transaction is a replacement, and no earlier attempt was mined",
      originals.length >= 1 && minedOriginals === 0, `${originals.length} replaced, ${minedOriginals} mined`);
    const mined = await pub.getTransaction({ hash: first.out.txHash });
    check("the replacement kept the original nonce", Number(mined.nonce) === first.out.nonce, `${mined.nonce}`);
    const nonces = [r1.out.nonce, r2.out.nonce].sort((a, b) => a - b);
    check("sequential nonces from one queue", nonces[1] === nonces[0] + 1, nonces.join(","));
  }
  check("nothing at rest in entry or router", (await atRest()) === 0n);
}

// ---------------------------------------------------------------- gas

console.log("\ngas per trade (L2 execution; this chain charges no L1 data component - see DEPLOYMENTS.md)");
const gp = BigInt(await call("eth_gasPrice", []));
for (const [k, g] of gasRows) console.log(`  ${k.padEnd(5)} ${String(g).padStart(8)} gas`);
console.log(`  deploy router ${deployGas.router} gas, entry ${deployGas.entry} gas`);
console.log(`  fork gas price ${gp} wei`);

console.log(`\nsender: ${JSON.stringify(sender.stats)}`);
console.log(`\n${failures} failures`);
fs.writeFileSync(path.join(ROOT, "deploy", "fork-e2e.json"), JSON.stringify({
  at: new Date().toISOString(), node: version, failures,
  gas: Object.fromEntries(gasRows.map(([k, g]) => [k, g.toString()])),
  deployGas: { router: deployGas.router.toString(), entry: deployGas.entry.toString() },
  sender: sender.stats,
}, null, 1) + "\n");
process.exit(failures ? 1 : 0);
