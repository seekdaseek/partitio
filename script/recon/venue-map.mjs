// G4 venue map: enumerate every routable venue for the stock-token universe on chain 4663.
//   v3     — factory.getPool across fee tiers, against USDG and WETH
//   v4     — poolId derived from PoolKey (hookless), probed via StateView
//   Rialto — propAMM pairs, probed via getAmountOut at rising sizes to find each maker's cap
// Everything here is read-only eth_call. Nothing is trusted that was not read back from the chain.
import fs from "node:fs";
import { keccak256, hexToBytes } from "./keccak.mjs";
import { RPC, sel, call, pool, blockNumber, addrArg, uintArg, boolArg, word, toAddr, toBig, toInt24 } from "./rpc.mjs";

const CFG = JSON.parse(fs.readFileSync(new URL("./tokens.json", import.meta.url)));
const { usdg: USDG, weth: WETH, tokens: TOKENS, uniswap: UNI, rialto: RIALTO } = CFG;
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
const V3_FEES = [100, 500, 3000, 10000];
const V4_KEYS = [[100, 1], [500, 10], [3000, 60], [10000, 200]];
const CONC = 8;

const sortPair = (a, b) => (BigInt(a) < BigInt(b) ? [a, b] : [b, a]);

async function erc20Meta(addr) {
  const [d, s] = await Promise.all([call(addr, sel("decimals()")), call(addr, sel("symbol()"))]);
  let sym = "?";
  if (s.ok && s.ok.length > 130) {
    const len = Number(toBig(word(s.ok, 1)));
    sym = Buffer.from(s.ok.replace(/^0x/, "").slice(128, 128 + len * 2), "hex").toString("utf8");
  }
  return { decimals: d.ok ? Number(toBig(d.ok)) : null, symbol: sym };
}

async function v3Pool(tokenA, tokenB, fee) {
  const r = await call(UNI.v3Factory, sel("getPool(address,address,uint24)") + addrArg(tokenA) + addrArg(tokenB) + uintArg(fee));
  if (!r.ok) return null;
  const addr = toAddr(word(r.ok, 0));
  if (addr === ZERO_ADDR) return null;
  const [liq, s0, balA, balB] = await Promise.all([
    call(addr, sel("liquidity()")),
    call(addr, sel("slot0()")),
    call(tokenA, sel("balanceOf(address)") + addrArg(addr)),
    call(tokenB, sel("balanceOf(address)") + addrArg(addr)),
  ]);
  const sqrtP = s0.ok ? toBig(word(s0.ok, 0)) : 0n;
  return {
    kind: "v3", addr, fee,
    liquidity: liq.ok ? toBig(word(liq.ok, 0)).toString() : null,
    active: liq.ok && toBig(word(liq.ok, 0)) > 0n,
    initialised: sqrtP !== 0n,
    sqrtPriceX96: sqrtP.toString(),
    tick: s0.ok ? Number(toInt24(word(s0.ok, 1))) : null,
    reserveA: balA.ok ? toBig(word(balA.ok, 0)).toString() : null,
    reserveB: balB.ok ? toBig(word(balB.ok, 0)).toString() : null,
  };
}

function poolId(c0, c1, fee, tickSpacing, hooks = ZERO_ADDR) {
  const enc = addrArg(c0) + addrArg(c1) + uintArg(fee) + uintArg(tickSpacing) + addrArg(hooks);
  return keccak256(hexToBytes(enc));
}

async function v4Pool(tokenA, tokenB, fee, tickSpacing) {
  const [c0, c1] = sortPair(tokenA, tokenB);
  const id = poolId(c0, c1, fee, tickSpacing);
  // Existence test is slot0.sqrtPriceX96 != 0 (initialised), NOT getLiquidity != 0.
  // getLiquidity returns only ACTIVE in-range liquidity: the SPY 500/10 pool on 4663 is
  // initialised (sqrtPriceX96 2.2e24, tick -209828) with 0 active liquidity, and a
  // liquidity-based test silently drops it. Verified against the chain 2026-09-24.
  const s0 = await call(UNI.stateView, sel("getSlot0(bytes32)") + id.replace(/^0x/, ""));
  if (!s0.ok) return null;
  const sqrtP = toBig(word(s0.ok, 0));
  if (sqrtP === 0n) return null;
  const liq = await call(UNI.stateView, sel("getLiquidity(bytes32)") + id.replace(/^0x/, ""));
  const L = liq.ok ? toBig(word(liq.ok, 0)) : null;
  return {
    kind: "v4", poolId: id, fee, tickSpacing, currency0: c0, currency1: c1, hooks: ZERO_ADDR,
    liquidity: L === null ? null : L.toString(),
    active: L !== null && L > 0n,
    sqrtPriceX96: sqrtP.toString(),
    tick: Number(toInt24(word(s0.ok, 1))),
    lpFee: Number(toBig(word(s0.ok, 3))),
  };
}

async function rialtoProbe(pairAddr, ticker, decimals) {
  const [t0, t1] = await Promise.all([call(pairAddr, sel("token0()")), call(pairAddr, sel("token1()"))]);
  if (!t0.ok || !t1.ok) return null;
  const token0 = toAddr(word(t0.ok, 0)), token1 = toAddr(word(t1.ok, 0));
  const stockIsT0 = token0.toLowerCase() === TOKENS[ticker].toLowerCase();
  const zeroForOne = stockIsT0;
  // walk sizes to find the maker's refusal cap (Rialto signals refusal with a 0 return)
  const sizes = [1, 3, 10, 30, 100, 300, 1000, 3000, 10000];
  const quotes = [];
  for (const s of sizes) {
    const amt = BigInt(s) * 10n ** BigInt(decimals);
    const r = await call(pairAddr, sel("getAmountOut(bool,uint256)") + boolArg(zeroForOne) + uintArg(amt));
    if (!r.ok) { quotes.push({ size: s, out: null, status: "revert" }); continue; }
    const out = toBig(word(r.ok, 0));
    quotes.push({ size: s, out: out.toString(), status: out === 0n ? "refused" : "ok" });
  }
  const lastOk = [...quotes].reverse().find((q) => q.status === "ok");
  return { kind: "rialto", addr: pairAddr, token0, token1, stockIsToken0: stockIsT0, quotes, capSize: lastOk ? lastOk.size : 0 };
}

const RIALTO_PAIRS = {
  COIN: "0xf57584c4e372052fcf48e2a3942b9c1087f011ad",
  SGOV: "0xe0db060b92de9094b9a49e1e82ca5f11dcb50a46",
  INTC: "0xe4c442a44b8ae699c95d313b2c407e4413ebe567",
  GOOGL: "0xdd479e2b6b114d23fd29e708da665678c1077c97",
  AMZN: "0x28691a561d0e1d6a2661dee41b75d3b688fc4479",
  META: "0xcd3d6b36f79ef74785bd1da226c9827b5a5c2dd8",
  MU: "0x0bf53c3bf003fbbf879a8677a7407c8c2743b30a",
  TSLA: "0x6af2cee71babfa22f9f55a16507cc4dc6369304b",
  SPY: "0x894b9322662f4e4ce05882f38095c6c7bcf1cc73",
  NVDA: "0x5744e9c5165973ba5a332135477f3000c143f16f",
  AAPL: "0x89e211d43bbcf8ca5eaa9e5fbdef078cf520ecf1",
};

(async () => {
  const block = await blockNumber();
  const at = new Date().toISOString();
  console.error(`# venue map · chain 4663 · block ${block} · ${at}`);
  console.error(`# rpc ${RPC}`);

  const tickers = Object.keys(TOKENS);
  const meta = {};
  for (const [name, addr] of [["USDG", USDG], ["WETH", WETH]]) meta[name] = { addr, ...(await erc20Meta(addr)) };
  const metas = await pool(CONC, tickers, async (t) => [t, await erc20Meta(TOKENS[t])]);
  for (const [t, m] of metas) meta[t] = { addr: TOKENS[t], ...m };

  const result = { block, at, rpc: RPC, meta, venues: {} };

  for (const t of tickers) {
    const tok = TOKENS[t];
    const jobs = [];
    for (const fee of V3_FEES) {
      jobs.push(["v3", "USDG", fee, () => v3Pool(tok, USDG, fee)]);
      jobs.push(["v3", "WETH", fee, () => v3Pool(tok, WETH, fee)]);
    }
    for (const [fee, ts] of V4_KEYS) {
      jobs.push(["v4", "USDG", fee, () => v4Pool(tok, USDG, fee, ts)]);
      jobs.push(["v4", "WETH", fee, () => v4Pool(tok, WETH, fee, ts)]);
    }
    const found = await pool(CONC, jobs, async ([kind, quote, fee, fn]) => {
      const r = await fn();
      return r ? { ...r, quote } : null;
    });
    const list = found.filter(Boolean);
    if (RIALTO_PAIRS[t]) {
      const rp = await rialtoProbe(RIALTO_PAIRS[t], t, meta[t].decimals);
      if (rp) list.push({ ...rp, quote: "USDG" });
    }
    result.venues[t] = list;
    const v3n = list.filter((v) => v.kind === "v3").length;
    const v3a = list.filter((v) => v.kind === "v3" && v.active).length;
    const v4n = list.filter((v) => v.kind === "v4").length;
    const v4a = list.filter((v) => v.kind === "v4" && v.active).length;
    const rn = list.filter((v) => v.kind === "rialto").length;
    console.error(`${t.padEnd(6)} v3=${v3a}/${v3n} v4=${v4a}/${v4n} rialto=${rn}  (${meta[t].symbol})`);
  }
  fs.writeFileSync(new URL("./venues.json", import.meta.url), JSON.stringify(result, null, 1));
  console.error("\nwrote script/recon/venues.json");
})();
