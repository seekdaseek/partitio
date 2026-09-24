-- partitio relayer. Every quote and every order is a timestamped row: these are the paired
-- samples the headline count is built from, so nothing is transient.

CREATE TABLE IF NOT EXISTS quote (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  at          TEXT NOT NULL,
  ip_hash     TEXT,                -- salted hash, never a raw IP
  direction   TEXT NOT NULL,       -- buy | sell
  ticker      TEXT NOT NULL,
  amount_in   TEXT NOT NULL,
  best_single TEXT,                -- best single venue, on-chain
  partitio    TEXT,                -- partitio split, on-chain
  kyber       TEXT,  kyber_status  TEXT,
  lifi        TEXT,  lifi_status   TEXT,
  zerox       TEXT,  zerox_status  TEXT,
  chosen      TEXT,                -- partitio | kyber | lifi | 0x
  chosen_out  TEXT,
  oracle_px   TEXT,
  oracle_dev_bps REAL,             -- expected deviation vs Chainlink at this size
  fee_usdg    TEXT,
  ms          INTEGER
);
CREATE INDEX IF NOT EXISTS quote_at ON quote(at);

CREATE TABLE IF NOT EXISTS orders (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  at          TEXT NOT NULL,
  order_hash  TEXT NOT NULL UNIQUE,
  owner       TEXT NOT NULL,
  is_team     INTEGER NOT NULL DEFAULT 0,   -- our own demo trades, labelled as ours everywhere
  direction   TEXT NOT NULL,
  ticker      TEXT NOT NULL,
  amount_in   TEXT NOT NULL,
  notional_usd REAL,
  chosen      TEXT,
  amount_out  TEXT,
  fee_usdg    TEXT,
  saved_vs_single TEXT,            -- what the split saved against the best single pool
  tx_hash     TEXT,
  status      TEXT NOT NULL,       -- simulated | submitted | confirmed | failed
  err         TEXT
);
CREATE INDEX IF NOT EXISTS orders_owner ON orders(owner, at);

-- per-address caps for the public beta
CREATE TABLE IF NOT EXISTS daily_use (
  owner      TEXT NOT NULL,
  day        TEXT NOT NULL,
  notional   REAL NOT NULL DEFAULT 0,
  fills      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (owner, day)
);
