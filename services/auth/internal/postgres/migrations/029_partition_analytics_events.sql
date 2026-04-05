-- ============================================================
-- services/auth/internal/postgres/migrations/029_partition_analytics_events.sql
-- Scope: auth service database only — independent migration sequence
--
-- Fixes:
--   F-SQL38 HIGH: analytics_events without partitioning
--
-- Down section symmetry fix applied:
--   Original Down did not restore chk_properties_size constraint.
--   Fixed to restore exact pre-Up state.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- Step 1: Drop existing indexes (will be recreated on new partitioned table)
DROP INDEX IF EXISTS idx_analytics_events_tenant_time;
DROP INDEX IF EXISTS idx_analytics_events_user;
DROP INDEX IF EXISTS idx_analytics_events_type;

-- Step 2: Rename existing table (preserves data)
ALTER TABLE analytics_events RENAME TO analytics_events_old;

-- Step 3: Create new partitioned table with exact same structure
CREATE TABLE analytics_events (
    id             BIGSERIAL    NOT NULL,
    tenant_id      TEXT         NOT NULL,
    user_id        TEXT         NOT NULL,
    session_id     TEXT,
    event_type     TEXT         NOT NULL,
    event_name     TEXT         NOT NULL,
    properties     JSONB        NOT NULL DEFAULT '{}',
    timestamp      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    ip_address     INET,
    user_agent     TEXT,
    CONSTRAINT chk_properties_size CHECK (length(properties::text) <= 102400)
) PARTITION BY RANGE (timestamp);

-- Step 4: Create partitions (monthly from 2025 through 2027)
CREATE TABLE analytics_events_2025_01 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE analytics_events_2025_02 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE analytics_events_2025_03 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE analytics_events_2025_04 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE analytics_events_2025_05 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE analytics_events_2025_06 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE analytics_events_2025_07 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE analytics_events_2025_08 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE analytics_events_2025_09 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE analytics_events_2025_10 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE analytics_events_2025_11 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
CREATE TABLE analytics_events_2025_12 PARTITION OF analytics_events
    FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');
CREATE TABLE analytics_events_2026_01 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE analytics_events_2026_02 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE analytics_events_2026_03 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE analytics_events_2026_04 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE analytics_events_2026_05 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE analytics_events_2026_06 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE analytics_events_2026_07 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE analytics_events_2026_08 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE analytics_events_2026_09 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE analytics_events_2026_10 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE analytics_events_2026_11 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE analytics_events_2026_12 PARTITION OF analytics_events
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE analytics_events_2027_01 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
CREATE TABLE analytics_events_2027_02 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-02-01') TO ('2027-03-01');
CREATE TABLE analytics_events_2027_03 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-03-01') TO ('2027-04-01');
CREATE TABLE analytics_events_2027_04 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-04-01') TO ('2027-05-01');
CREATE TABLE analytics_events_2027_05 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-05-01') TO ('2027-06-01');
CREATE TABLE analytics_events_2027_06 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-06-01') TO ('2027-07-01');
CREATE TABLE analytics_events_2027_07 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-07-01') TO ('2027-08-01');
CREATE TABLE analytics_events_2027_08 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-08-01') TO ('2027-09-01');
CREATE TABLE analytics_events_2027_09 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-09-01') TO ('2027-10-01');
CREATE TABLE analytics_events_2027_10 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-10-01') TO ('2027-11-01');
CREATE TABLE analytics_events_2027_11 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-11-01') TO ('2027-12-01');
CREATE TABLE analytics_events_2027_12 PARTITION OF analytics_events
    FOR VALUES FROM ('2027-12-01') TO ('2028-01-01');

-- Default partition for future dates
CREATE TABLE analytics_events_default PARTITION OF analytics_events DEFAULT;

-- Step 5: Recreate indexes (automatically applied to all partitions)
CREATE INDEX idx_analytics_events_tenant_time
    ON analytics_events (tenant_id, timestamp DESC);
CREATE INDEX idx_analytics_events_user
    ON analytics_events (tenant_id, user_id, timestamp);
CREATE INDEX idx_analytics_events_type
    ON analytics_events (event_type, event_name);

-- Step 6: Migrate data from old table (if any exists)
INSERT INTO analytics_events
    SELECT * FROM analytics_events_old;

-- Step 7: Drop old table
DROP TABLE analytics_events_old;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Reverse: drop indexes, rename partitioned → create non-partitioned
-- with EXACT same structure as pre-Up state → insert → drop
DROP INDEX IF EXISTS idx_analytics_events_tenant_time;
DROP INDEX IF EXISTS idx_analytics_events_user;
DROP INDEX IF EXISTS idx_analytics_events_type;

ALTER TABLE analytics_events RENAME TO analytics_events_partitioned;

-- Restore exact pre-Up structure including chk_properties_size
CREATE TABLE analytics_events (
    id             BIGSERIAL    NOT NULL,
    tenant_id      TEXT         NOT NULL,
    user_id        TEXT         NOT NULL,
    session_id     TEXT,
    event_type     TEXT         NOT NULL,
    event_name     TEXT         NOT NULL,
    properties     JSONB        NOT NULL DEFAULT '{}',
    timestamp      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    ip_address     INET,
    user_agent     TEXT,
    CONSTRAINT chk_properties_size CHECK (length(properties::text) <= 102400)
);

CREATE INDEX idx_analytics_events_tenant_time
    ON analytics_events (tenant_id, timestamp DESC);
CREATE INDEX idx_analytics_events_user
    ON analytics_events (tenant_id, user_id, timestamp);
CREATE INDEX idx_analytics_events_type
    ON analytics_events (event_type, event_name);

INSERT INTO analytics_events
    SELECT * FROM analytics_events_partitioned;

DROP TABLE analytics_events_partitioned;

-- +goose StatementEnd
