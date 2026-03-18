-- services/ingestion/internal/postgres/migrations/001_init_schema.sql
-- +goose Up
-- +goose StatementBegin

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

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
    archived_at    TIMESTAMPTZ  NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_warm_events_event_id
    ON warm_events (event_id);

CREATE INDEX IF NOT EXISTS idx_warm_events_tenant_time
    ON warm_events (tenant_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_warm_events_type
    ON warm_events (event_type);

CREATE INDEX IF NOT EXISTS idx_warm_events_occurred_at
    ON warm_events (occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_warm_events_not_archived
    ON warm_events (occurred_at)
    WHERE archived_at IS NULL;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS warm_events CASCADE;
-- +goose StatementEnd
