-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS regulatory_reports (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    report_type    TEXT      NOT NULL,
    period_start   TIMESTAMPTZ NOT NULL,
    period_end     TIMESTAMPTZ NOT NULL,
    report_data    JSONB     NOT NULL,
    generated_by   TEXT      NOT NULL,
    generated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status         TEXT      NOT NULL DEFAULT 'pending',
    error_msg      TEXT,
    download_url   TEXT
);

CREATE TABLE IF NOT EXISTS data_license_usage (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    data_source    TEXT      NOT NULL,
    usage_type     TEXT      NOT NULL,
    usage_count    INTEGER   NOT NULL DEFAULT 1,
    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS disclaimer_acceptances (
    id             BIGSERIAL PRIMARY KEY,
    user_id        TEXT      NOT NULL,
    tenant_id      TEXT      NOT NULL,
    disclaimer_type TEXT     NOT NULL,
    version        TEXT      NOT NULL,
    accepted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address     INET,
    user_agent     TEXT
);

CREATE INDEX IF NOT EXISTS idx_regulatory_reports_tenant_period ON regulatory_reports(tenant_id, period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_data_license_usage_tenant_source ON data_license_usage(tenant_id, data_source, recorded_at);
CREATE INDEX IF NOT EXISTS idx_disclaimer_acceptances_user ON disclaimer_acceptances(user_id, disclaimer_type);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS disclaimer_acceptances CASCADE;
DROP TABLE IF EXISTS data_license_usage CASCADE;
DROP TABLE IF EXISTS regulatory_reports CASCADE;
-- +goose StatementEnd
