-- migrations/postgres/001_init_schema.sql
-- +goose Up
-- +goose StatementBegin

-- ── Extensions ────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- للـ gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- للـ full-text search على event_type

-- ── Warm Events Table ─────────────────────────────────────────────────────
-- بيانات انتقلت من ClickHouse بعد انتهاء الـ TTL (7 أيام)
CREATE TABLE IF NOT EXISTS warm_events (
    id             BIGSERIAL    PRIMARY KEY,
    event_id       TEXT         NOT NULL,
    event_type     TEXT         NOT NULL,
    source         TEXT         NOT NULL DEFAULT '',
    schema_version TEXT         NOT NULL DEFAULT '1.0.0',
    tenant_id      TEXT         NOT NULL DEFAULT '',
    partition_key  TEXT         NOT NULL DEFAULT '',
    content_type   TEXT         NOT NULL DEFAULT 'application/json',
    payload        TEXT         NOT NULL DEFAULT '',
    payload_bytes  INTEGER      NOT NULL DEFAULT 0,
    trace_id       TEXT         NOT NULL DEFAULT '',
    span_id        TEXT         NOT NULL DEFAULT '',
    occurred_at    TIMESTAMPTZ  NOT NULL,
    ingested_at    TIMESTAMPTZ  NOT NULL,
    archived_at    TIMESTAMPTZ  NULL,       -- وقت النقل لـ S3 (Cold)
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ── Indexes ───────────────────────────────────────────────────────────────
-- Index على tenant_id + occurred_at — الـ query الأكثر شيوعاً
CREATE INDEX IF NOT EXISTS idx_warm_events_tenant_time
    ON warm_events (tenant_id, occurred_at DESC);

-- Index على event_type — للفلترة
CREATE INDEX IF NOT EXISTS idx_warm_events_type
    ON warm_events (event_type);

-- Index على event_id — للـ deduplication
CREATE UNIQUE INDEX IF NOT EXISTS idx_warm_events_event_id
    ON warm_events (event_id);

-- Index على occurred_at — للـ archival job
CREATE INDEX IF NOT EXISTS idx_warm_events_occurred_at
    ON warm_events (occurred_at DESC);

-- Index على archived_at IS NULL — للـ cold archival query
CREATE INDEX IF NOT EXISTS idx_warm_events_not_archived
    ON warm_events (occurred_at)
    WHERE archived_at IS NULL;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS warm_events CASCADE;
-- +goose StatementEnd
