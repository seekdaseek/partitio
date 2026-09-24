-- partitio evidence engine. One row per measurement, never an imputed zero.
-- A call that failed is status='unmeasured' with amount_out NULL. A maker that declined a size
-- is status='refused' with amount_out 0 — those are different facts and must stay distinguishable.

CREATE TABLE IF NOT EXISTS run (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at   TEXT NOT NULL,
  finished_at  TEXT,
  block        INTEGER,
  gas_price    TEXT,
  router_addr  TEXT,               -- NULL until the router is deployed
  note         TEXT
);

-- Per-venue quote at one size. venue_id is a pool address or a v4 poolId.
CREATE TABLE IF NOT EXISTS quote (
  run_id      INTEGER NOT NULL REFERENCES run(id),
  ticker      TEXT NOT NULL,
  size_usd    INTEGER NOT NULL,
  amount_in   TEXT NOT NULL,
  family      TEXT NOT NULL,       -- uniswapv3 | up-v3 | uniswap-v4 | fermi-prop | ...
  kind        TEXT NOT NULL,       -- v3 | v4 | maker
  venue_id    TEXT NOT NULL,
  chunk_ix    INTEGER NOT NULL,    -- 0 = full size; 1..K = cumulative ladder point for the split
  amount_out  TEXT,                -- NULL when unmeasured
  status      TEXT NOT NULL,       -- ok | refused | unmeasured
  err         TEXT
);
CREATE INDEX IF NOT EXISTS quote_run   ON quote(run_id, ticker, size_usd);
CREATE INDEX IF NOT EXISTS quote_venue ON quote(venue_id);

-- One row per (run, ticker, size): the comparison the submission actually quotes.
CREATE TABLE IF NOT EXISTS agg (
  run_id             INTEGER NOT NULL REFERENCES run(id),
  ticker             TEXT NOT NULL,
  size_usd           INTEGER NOT NULL,
  amount_in          TEXT NOT NULL,
  best_venue_out     TEXT,  best_venue_id   TEXT,  best_venue_family TEXT,
  best_v3_out        TEXT,  best_v4_out     TEXT,  best_maker_out    TEXT,
  split_out          TEXT,                  -- greedy split total
  split_kind         TEXT,                  -- split_sim | split_router
  split_legs         TEXT,                  -- JSON [{venue_id, family, amount_in, amount_out}]
  split_venue_count  INTEGER,
  kyber_all_out      TEXT,  kyber_all_status    TEXT,
  kyber_onchain_out  TEXT,  kyber_onchain_status TEXT,
  lifi_out           TEXT,  lifi_status         TEXT,
  PRIMARY KEY (run_id, ticker, size_usd)
);

-- Which venue families Kyber was restricted to for the on-chain yardstick, per run.
CREATE TABLE IF NOT EXISTS kyber_sources (
  run_id INTEGER NOT NULL REFERENCES run(id),
  included TEXT NOT NULL
);
