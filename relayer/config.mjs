// Relayer configuration. Secrets are READ FROM FILES, never from argv and never logged.
import fs from "node:fs";
import path from "node:path";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const readIf = (p) => { try { const v = fs.readFileSync(p, "utf8").trim(); return v || null; } catch { return null; } };

// QuickNode for relayer work; canonical and publicnode as fallbacks. The QuickNode free trial
// ends ~Oct 24 and results land Oct 25, so the fallback is automatic rather than a manual fix.
// PARTITIO_RPC_OVERRIDE replaces the whole list - it exists for the local anvil fork, where a
// fallback to a mainnet endpoint would silently send a "test" somewhere real.
export const RPCS = process.env.PARTITIO_RPC_OVERRIDE
  ? [process.env.PARTITIO_RPC_OVERRIDE]
  : [
      readIf(path.join(HERE, "qn_rpc")) || readIf(`${process.env.HOME}/.config/partitio/qn_rpc`),
      "https://robinhood-rpc.publicnode.com",
      "https://rpc.mainnet.chain.robinhood.com",
    ].filter(Boolean);

export const HOT_KEY_FILE = path.join(HERE, "hotkey");   // 0600, generated ON the VPS
export const DB_PATH = process.env.PARTITIO_RELAYER_DB || path.join(HERE, "relayer.db");
export const PORT = Number(process.env.PARTITIO_RELAYER_PORT || 3031);

export const CHAIN_ID = 4663;
export const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
export const QUOTER_V2 = "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7";
export const V4_QUOTER = "0x8dc178efb8111bb0973dd9d722ebeff267c98f94";

// Set once router v2 + GaslessEntry are deployed. Until then the relayer quotes but will not
// accept orders, and says so rather than failing obscurely.
export const ROUTER_V2 = process.env.PARTITIO_ROUTER_V2 || null;
export const GASLESS_ENTRY = process.env.PARTITIO_GASLESS_ENTRY || null;

// Public beta caps
export const MAX_TRADE_USD = Number(process.env.PARTITIO_MAX_TRADE_USD || 50);
export const MAX_DAILY_USD_PER_ADDRESS = Number(process.env.PARTITIO_MAX_DAILY_USD || 200);
export const MAX_DAILY_FILLS_PER_ADDRESS = Number(process.env.PARTITIO_MAX_DAILY_FILLS || 10);
export const QUOTE_RATE_PER_MIN = Number(process.env.PARTITIO_QUOTE_RATE || 30);

// Float management. Below FLOAT_MIN the app degrades to quotes-only with a banner — never to down.
export const FLOAT_MIN_WEI = BigInt(process.env.PARTITIO_FLOAT_MIN_WEI || "20000000000000");   // 0.00002
export const FLOAT_TARGET_WEI = BigInt(process.env.PARTITIO_FLOAT_TARGET_WEI || "200000000000000"); // 0.0002

// Our own demo wallets, labelled as ours everywhere they appear.
export const TEAM_ADDRESSES = new Set(
  (process.env.PARTITIO_TEAM_ADDRESSES || "0x7a7c915D8dA490c48915Fe735DDf41f8Dea83dC2,0x119aa61fC2c33F8e2c58370991Dc9fA5d6E3f399")
    .toLowerCase().split(",").map((s) => s.trim()).filter(Boolean)
);

export const IP_SALT = readIf(path.join(HERE, "ip_salt")) || "partitio-dev-salt";
