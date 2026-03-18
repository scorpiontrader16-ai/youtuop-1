-- migrations/postgres/002_tiering_metadata.sql
-- +goose Up
-- +goose StatementBegin

-- ── Tiering Jobs Table ────────────────────────────────────────────────────
-- يتتبع حالة نقل البيانات بين الـ tiers
CREATE TABLE IF NOT EXISTS tiering_jobs (
    id           BIGSERIAL   PRIMARY KEY,
    job_id       TEXT        NOT NULL UNIQUE DEFAULT gen_random_uuid()::TEXT,
    job_type     TEXT        NOT NULL,   -- "hot_to_warm" | "warm_to_cold"
    status       TEXT        NOT NULL DEFAULT 'pending',
                                         -- pending | running | done | failed
    tenant_id    TEXT        NOT NULL DEFAULT '',
    from_date    TIMESTAMPTZ NOT NULL,
    to_date      TIMESTAMPTZ NOT NULL,
    rows_moved   BIGINT      NOT NULL DEFAULT 0,
    error_msg    TEXT        NOT NULL DEFAULT '',
    started_at   TIMESTAMPTZ NULL,
    finished_at  TIMESTAMPTZ NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_job_type   CHECK (job_type IN ('hot_to_warm', 'warm_to_cold')),
    CONSTRAINT chk_status     CHECK (status IN ('pending', 'running', 'done', 'failed')),
    CONSTRAINT chk_date_range CHECK (from_date < to_date)
);

CREATE INDEX IF NOT EXISTS idx_tiering_jobs_status
    ON tiering_jobs (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tiering_jobs_type_status
    ON tiering_jobs (job_type, status);

-- ── Schema Versions Table ─────────────────────────────────────────────────
-- يتتبع الـ proto schema versions المستخدمة
CREATE TABLE IF NOT EXISTS schema_versions (
    id             BIGSERIAL   PRIMARY KEY,
    subject        TEXT        NOT NULL,
    version        INTEGER     NOT NULL,
    schema_id      INTEGER     NOT NULL,
    schema_content TEXT        NOT NULL,
    registered_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_schema_subject_version UNIQUE (subject, version)
);

CREATE INDEX IF NOT EXISTS idx_schema_versions_subject
    ON schema_versions (subject, version DESC);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS schema_versions CASCADE;
DROP TABLE IF EXISTS tiering_jobs    CASCADE;
-- +goose StatementEnd
