-- ============================================================
-- services/ingestion/internal/postgres/migrations/008_fix_warm_events_year_end_gaps.sql
-- Scope: ingestion service database only — independent migration sequence
--
-- Fixes:
--   F-SQL32 PARTIAL (year-end gaps): warm_events w52 partitions for
--   2025, 2026, and 2027 were created with TO ('YYYY-12-31').
--   In PostgreSQL RANGE partitioning, the TO bound is EXCLUSIVE,
--   so timestamps on December 31st (00:00:00 through 23:59:59.999999)
--   fell into warm_events_default rather than the correct weekly partition.
--
--   Effect:
--     - 3 days per year (Dec 31 of 2025, 2026, 2027) bypassed
--       explicit partitions -> full sequential scan on default partition
--       for any query touching those dates.
--     - DROP-based retention cleanup for those days was not possible
--       (data lived in default, not a droppable weekly partition).
--
--   Fix:
--     Extend w52 boundary for each year: TO ('YYYY-12-31') ->
--     TO ('YYYY+1-01-01'), eliminating the gap without creating
--     any overlap (w01 of the next year starts at YYYY+1-01-01).
--
--   Strategy:
--     PostgreSQL does not support ALTER TABLE to change range bounds
--     on an existing partition. Must use:
--       1. Rescue ALL data from old w52 (Dec 24-30) into temp table
--       2. Rescue Dec 31 data from warm_events_default into temp table
--       3. DROP old w52 (data already rescued -- no loss)
--       4. CREATE corrected w52 with TO ('YYYY+1-01-01')
--       5. INSERT all rescued data back into warm_events
--          (Dec 24-30 routes to new w52; Dec 31 routes to new w52)
--       6. DROP temp rescue tables
--
--   Safety:
--     - Zero data loss: all rows rescued before any DROP.
--     - Down section is fully symmetric and also zero data loss.
--     - TEMP tables are session-scoped -- auto-cleaned on disconnect.
--     - In Codespace (empty tables): rescue SELECTs return 0 rows;
--       INSERTs are no-ops. Migration runs cleanly in either state.
--     - In production with data: requires maintenance window.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- 2025-12-31 gap fix
-- Old: FROM ('2025-12-24') TO ('2025-12-31')  -- Dec 31 falls to default
-- New: FROM ('2025-12-24') TO ('2026-01-01')  -- Dec 31 covered

CREATE TEMP TABLE warm_events_2025_w52_rescue AS
    SELECT * FROM warm_events_2025_w52;

CREATE TEMP TABLE warm_events_2025_dec31_rescue AS
    SELECT * FROM warm_events_default
    WHERE occurred_at >= '2025-12-31'
      AND occurred_at <  '2026-01-01';

DROP TABLE warm_events_2025_w52;

CREATE TABLE warm_events_2025_w52
    PARTITION OF warm_events
    FOR VALUES FROM ('2025-12-24') TO ('2026-01-01');

INSERT INTO warm_events SELECT * FROM warm_events_2025_w52_rescue;
INSERT INTO warm_events SELECT * FROM warm_events_2025_dec31_rescue;

DROP TABLE warm_events_2025_w52_rescue;
DROP TABLE warm_events_2025_dec31_rescue;

-- 2026-12-31 gap fix
-- Old: FROM ('2026-12-24') TO ('2026-12-31')  -- Dec 31 falls to default
-- New: FROM ('2026-12-24') TO ('2027-01-01')  -- Dec 31 covered

CREATE TEMP TABLE warm_events_2026_w52_rescue AS
    SELECT * FROM warm_events_2026_w52;

CREATE TEMP TABLE warm_events_2026_dec31_rescue AS
    SELECT * FROM warm_events_default
    WHERE occurred_at >= '2026-12-31'
      AND occurred_at <  '2027-01-01';

DROP TABLE warm_events_2026_w52;

CREATE TABLE warm_events_2026_w52
    PARTITION OF warm_events
    FOR VALUES FROM ('2026-12-24') TO ('2027-01-01');

INSERT INTO warm_events SELECT * FROM warm_events_2026_w52_rescue;
INSERT INTO warm_events SELECT * FROM warm_events_2026_dec31_rescue;

DROP TABLE warm_events_2026_w52_rescue;
DROP TABLE warm_events_2026_dec31_rescue;

-- 2027-12-31 gap fix
-- Old: FROM ('2027-12-24') TO ('2027-12-31')  -- Dec 31 falls to default
-- New: FROM ('2027-12-24') TO ('2028-01-01')  -- Dec 31 covered

CREATE TEMP TABLE warm_events_2027_w52_rescue AS
    SELECT * FROM warm_events_2027_w52;

CREATE TEMP TABLE warm_events_2027_dec31_rescue AS
    SELECT * FROM warm_events_default
    WHERE occurred_at >= '2027-12-31'
      AND occurred_at <  '2028-01-01';

DROP TABLE warm_events_2027_w52;

CREATE TABLE warm_events_2027_w52
    PARTITION OF warm_events
    FOR VALUES FROM ('2027-12-24') TO ('2028-01-01');

INSERT INTO warm_events SELECT * FROM warm_events_2027_w52_rescue;
INSERT INTO warm_events SELECT * FROM warm_events_2027_dec31_rescue;

DROP TABLE warm_events_2027_w52_rescue;
DROP TABLE warm_events_2027_dec31_rescue;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Reverse: restore original w52 boundaries (TO Dec 31 exclusive).
-- Fully symmetric rescue pattern -- zero data loss in rollback.
-- After rollback: Dec 31 data routes to warm_events_default.

-- Reverse 2025
CREATE TEMP TABLE warm_events_2025_w52_rescue AS
    SELECT * FROM warm_events_2025_w52;

DROP TABLE warm_events_2025_w52;

CREATE TABLE warm_events_2025_w52
    PARTITION OF warm_events
    FOR VALUES FROM ('2025-12-24') TO ('2025-12-31');

INSERT INTO warm_events SELECT * FROM warm_events_2025_w52_rescue;

DROP TABLE warm_events_2025_w52_rescue;

-- Reverse 2026
CREATE TEMP TABLE warm_events_2026_w52_rescue AS
    SELECT * FROM warm_events_2026_w52;

DROP TABLE warm_events_2026_w52;

CREATE TABLE warm_events_2026_w52
    PARTITION OF warm_events
    FOR VALUES FROM ('2026-12-24') TO ('2026-12-31');

INSERT INTO warm_events SELECT * FROM warm_events_2026_w52_rescue;

DROP TABLE warm_events_2026_w52_rescue;

-- Reverse 2027
CREATE TEMP TABLE warm_events_2027_w52_rescue AS
    SELECT * FROM warm_events_2027_w52;

DROP TABLE warm_events_2027_w52;

CREATE TABLE warm_events_2027_w52
    PARTITION OF warm_events
    FOR VALUES FROM ('2027-12-24') TO ('2027-12-31');

INSERT INTO warm_events SELECT * FROM warm_events_2027_w52_rescue;

DROP TABLE warm_events_2027_w52_rescue;

-- +goose StatementEnd
