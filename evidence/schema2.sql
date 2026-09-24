-- partitio evidence engine v2. Fresh database: v2 measures BOTH directions and classifies every
-- Kyber response, so its rows are not comparable row-for-row with v1's. The v1 database is kept
-- as partitio.db rather than migrated, which is the series break made explicit.

CREATE TABLE IF NOT EXISTS run (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at   TEXT NOT NULL,
  finished_at  TEXT,
  block        INTEGER,
  gas_price    TEXT,
  router_addr  TEXT,
  note         TEXT
);

CREATE TABLE IF NOT EXISTS quote (
  run_id      INTEGER NOT NULL REFERENCES run(id),
  ticker      TEXT NOT NULL,
  direction   TEXT NOT NULL,       -- buy = USDG->stock | sell = stock->USDG
  size_usd    INTEGER NOT NULL,
  amount_in   TEXT NOT NULL,
  family      TEXT NOT NULL,
  kind        TEXT NOT NULL,       -- v3 | v4 | maker
  venue_id    TEXT NOT NULL,
  chunk_ix    INTEGER NOT NULL,    -- 1..K cumulative ladder rung
  amount_out  TEXT,                -- NULL when unmeasured. NEVER an imputed zero.
  status      TEXT NOT NULL,       -- ok | refused | unmeasured
  err         TEXT
);
CREATE INDEX IF NOT EXISTS quote_run ON quote(run_id, ticker, direction, size_usd);

CREATE TABLE IF NOT EXISTS agg (
  run_id             INTEGER NOT NULL REFERENCES run(id),
  ticker             TEXT NOT NULL,
  direction          TEXT NOT NULL,
  size_usd           INTEGER NOT NULL,
  amount_in          TEXT NOT NULL,
  best_venue_out     TEXT,  best_venue_id   TEXT,  best_venue_family TEXT,
  best_v3_out        TEXT,  best_v4_out     TEXT,  best_maker_out    TEXT,
  split_out          TEXT,
  split_kind         TEXT,                  -- split_sim | split_router
  split_legs         TEXT,
  split_venue_count  INTEGER,
  kyber_all_out      TEXT,  kyber_all_status TEXT,
  kyber_onchain_out  TEXT,  kyber_onchain_status TEXT,
  lifi_out           TEXT,  lifi_status     TEXT,
  PRIMARY KEY (run_id, ticker, direction, size_usd)
);

-- Every Kyber response, classified. Availability and degradation become measurable rather than
-- anecdotal: "3 of 5 browser requests failed" is not a number we can publish.
CREATE TABLE IF NOT EXISTS kyber_call (
  run_id     INTEGER NOT NULL REFERENCES run(id),
  at         TEXT NOT NULL,
  ticker     TEXT NOT NULL,
  direction  TEXT NOT NULL,
  size_usd   INTEGER NOT NULL,
  restricted INTEGER NOT NULL,     -- 1 = includedSources was sent
  status     TEXT NOT NULL,        -- ok | unmeasured
  cls        TEXT,                 -- overloaded | rate-limited | no-route | transport | error
  http       INTEGER,
  api_code   INTEGER,
  hops       INTEGER,
  families   TEXT,
  rfq_share  REAL,                 -- % of route output via off-chain RFQ ids
  amount_out TEXT,
  err        TEXT
);
CREATE INDEX IF NOT EXISTS kyber_run ON kyber_call(run_id);

CREATE TABLE IF NOT EXISTS kyber_sources (
  run_id INTEGER NOT NULL REFERENCES run(id),
  included TEXT NOT NULL
);
