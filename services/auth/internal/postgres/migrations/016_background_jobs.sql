-- +goose Up
-- +goose StatementBegin

-- جدول الوظائف (jobs)
CREATE TABLE IF NOT EXISTS background_jobs (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    job_type       TEXT      NOT NULL,
    job_name       TEXT      NOT NULL,
    payload        JSONB     NOT NULL DEFAULT '{}',
    status         TEXT      NOT NULL DEFAULT 'pending',
    priority       INTEGER   NOT NULL DEFAULT 5,
    scheduled_for  TIMESTAMPTZ,
    started_at     TIMESTAMPTZ,
    finished_at    TIMESTAMPTZ,
    retry_count    INTEGER   NOT NULL DEFAULT 0,
    max_retries    INTEGER   NOT NULL DEFAULT 3,
    error_msg      TEXT,
    result         JSONB,
    created_by     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT check_status CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
    CONSTRAINT check_priority CHECK (priority BETWEEN 0 AND 10)
);

-- جدول سجلات تنفيذ الوظائف (audit)
CREATE TABLE IF NOT EXISTS background_job_logs (
    id             BIGSERIAL PRIMARY KEY,
    job_id         BIGINT    NOT NULL REFERENCES background_jobs(id) ON DELETE CASCADE,
    attempt        INTEGER   NOT NULL,
    status         TEXT      NOT NULL,
    error_msg      TEXT,
    started_at     TIMESTAMPTZ NOT NULL,
    finished_at    TIMESTAMPTZ,
    duration_ms    INTEGER
);

-- جدول الوظائف المجدولة (cron)
CREATE TABLE IF NOT EXISTS cron_jobs (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    job_type       TEXT      NOT NULL,
    job_name       TEXT      NOT NULL,
    schedule       TEXT      NOT NULL,
    payload        JSONB     NOT NULL DEFAULT '{}',
    enabled        BOOLEAN   NOT NULL DEFAULT TRUE,
    last_run_at    TIMESTAMPTZ,
    next_run_at    TIMESTAMPTZ,
    created_by     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- فهارس محسنة
CREATE INDEX IF NOT EXISTS idx_background_jobs_status_priority ON background_jobs(status, priority, scheduled_for) WHERE status IN ('pending', 'running');
CREATE INDEX IF NOT EXISTS idx_background_jobs_tenant ON background_jobs(tenant_id, created_at);
CREATE INDEX IF NOT EXISTS idx_background_jobs_scheduled ON background_jobs(scheduled_for) WHERE scheduled_for IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_cron_jobs_next_run ON cron_jobs(next_run_at) WHERE enabled = true;
CREATE INDEX IF NOT EXISTS idx_cron_jobs_tenant ON cron_jobs(tenant_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS cron_jobs CASCADE;
DROP TABLE IF EXISTS background_job_logs CASCADE;
DROP TABLE IF EXISTS background_jobs CASCADE;
-- +goose StatementEnd
