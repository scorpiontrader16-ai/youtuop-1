-- ============================================================
-- 008_audit_compliance.sql
-- M14 Audit & Compliance
-- يبني فوق كل الـ tables الموجودة
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ── 1. Audit Log (append-only — immutable) ──────────────────
-- مفيش UPDATE، مفيش DELETE — بس INSERT
-- مقسم بالشهر للـ performance
CREATE TABLE IF NOT EXISTS audit_log (
    id          BIGSERIAL    NOT NULL,
    tenant_id   TEXT,
    user_id     TEXT,
    action      TEXT         NOT NULL,
    resource    TEXT         NOT NULL,
    resource_id TEXT,
    old_data    JSONB,
    new_data    JSONB,
    ip_address  TEXT,
    user_agent  TEXT,
    trace_id    TEXT,
    status      TEXT         NOT NULL DEFAULT 'success',
    error       TEXT,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_audit_status CHECK (status IN ('success', 'failure'))
) PARTITION BY RANGE (created_at);

-- ── Partitions ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log_2025_q1
    PARTITION OF audit_log
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');

CREATE TABLE IF NOT EXISTS audit_log_2025_q2
    PARTITION OF audit_log
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');

CREATE TABLE IF NOT EXISTS audit_log_2025_q3
    PARTITION OF audit_log
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');

CREATE TABLE IF NOT EXISTS audit_log_2025_q4
    PARTITION OF audit_log
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');

CREATE TABLE IF NOT EXISTS audit_log_2026_q1
    PARTITION OF audit_log
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');

CREATE TABLE IF NOT EXISTS audit_log_2026_q2
    PARTITION OF audit_log
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

CREATE TABLE IF NOT EXISTS audit_log_2026_q3
    PARTITION OF audit_log
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

CREATE TABLE IF NOT EXISTS audit_log_2026_q4
    PARTITION OF audit_log
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

-- ── Indexes على كل الـ partitions ────────────────────────────
CREATE INDEX IF NOT EXISTS idx_audit_tenant_created
    ON audit_log (tenant_id, created_at DESC)
    WHERE tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_user_created
    ON audit_log (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_resource
    ON audit_log (resource, resource_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_action
    ON audit_log (action, created_at DESC);

-- ── 2. Data Retention Policies ───────────────────────────────
CREATE TABLE IF NOT EXISTS data_retention_policies (
    id              TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    resource_type   TEXT        NOT NULL UNIQUE,
    retention_days  INTEGER     NOT NULL,
    auto_delete     BOOLEAN     NOT NULL DEFAULT FALSE,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_retention_days CHECK (retention_days > 0)
);

-- ── 3. GDPR Data Requests ────────────────────────────────────
CREATE TABLE IF NOT EXISTS gdpr_requests (
    id            TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    tenant_id     TEXT        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id       TEXT        NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    type          TEXT        NOT NULL,
    status        TEXT        NOT NULL DEFAULT 'pending',
    requested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at  TIMESTAMPTZ,
    expires_at    TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '30 days',
    data_export   JSONB,
    notes         TEXT,
    CONSTRAINT chk_gdpr_type   CHECK (type   IN ('access', 'deletion', 'portability', 'rectification')),
    CONSTRAINT chk_gdpr_status CHECK (status IN ('pending', 'processing', 'completed', 'rejected'))
);

CREATE INDEX IF NOT EXISTS idx_gdpr_tenant
    ON gdpr_requests (tenant_id, requested_at DESC);

CREATE INDEX IF NOT EXISTS idx_gdpr_user
    ON gdpr_requests (user_id, requested_at DESC);

CREATE INDEX IF NOT EXISTS idx_gdpr_status
    ON gdpr_requests (status, expires_at)
    WHERE status = 'pending';

-- ── 4. Legal Hold ────────────────────────────────────────────
-- تجميد بيانات لو في قضية قانونية
CREATE TABLE IF NOT EXISTS legal_holds (
    id          TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    tenant_id   TEXT        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    reason      TEXT        NOT NULL,
    placed_by   TEXT        NOT NULL REFERENCES users(id),
    placed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at TIMESTAMPTZ,
    active      BOOLEAN     NOT NULL DEFAULT TRUE,
    notes       TEXT
);

CREATE INDEX IF NOT EXISTS idx_legal_holds_tenant
    ON legal_holds (tenant_id)
    WHERE active = TRUE;

-- ── 5. Compliance Dashboard Snapshots ────────────────────────
CREATE TABLE IF NOT EXISTS compliance_snapshots (
    id           BIGSERIAL    PRIMARY KEY,
    tenant_id    TEXT         REFERENCES tenants(id) ON DELETE CASCADE,
    period_start TIMESTAMPTZ  NOT NULL,
    period_end   TIMESTAMPTZ  NOT NULL,
    metrics      JSONB        NOT NULL DEFAULT '{}',
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_compliance_snapshots_tenant
    ON compliance_snapshots (tenant_id, period_start DESC)
    WHERE tenant_id IS NOT NULL;

-- ── 6. Prevent DELETE/UPDATE on audit_log ────────────────────
-- يمنع أي تعديل على الـ audit records — tamper-proof
-- نستخدم trigger لأن RULE لا تعمل على partitioned tables
CREATE OR REPLACE FUNCTION audit_log_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is immutable — DELETE and UPDATE are not permitted';
END;
$$;

CREATE TRIGGER trg_audit_log_no_delete
    BEFORE DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_immutable();

CREATE TRIGGER trg_audit_log_no_update
    BEFORE UPDATE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_immutable();

-- ── 7. Seed: Default Retention Policies ──────────────────────
INSERT INTO data_retention_policies (resource_type, retention_days, auto_delete, description) VALUES
    ('audit_log',           2555, FALSE, 'Audit logs — 7 years (regulatory requirement)'),
    ('sessions',             90,  TRUE,  'User sessions — 90 days'),
    ('refresh_tokens',       30,  TRUE,  'Refresh tokens — 30 days'),
    ('notifications',       365,  TRUE,  'In-app notifications — 1 year'),
    ('email_log',           365,  FALSE, 'Email audit log — 1 year'),
    ('billing_events',     2555,  FALSE, 'Billing events — 7 years (financial records)'),
    ('usage_records',       730,  FALSE, 'Usage records — 2 years'),
    ('warm_events',          30,  TRUE,  'Hot event cache — 30 days'),
    ('gdpr_requests',       365,  FALSE, 'GDPR requests — 1 year after completion')
ON CONFLICT (resource_type) DO NOTHING;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TRIGGER IF EXISTS trg_audit_log_no_update ON audit_log;
DROP TRIGGER IF EXISTS trg_audit_log_no_delete ON audit_log;
DROP FUNCTION IF EXISTS audit_log_immutable();

DROP TABLE IF EXISTS compliance_snapshots    CASCADE;
DROP TABLE IF EXISTS legal_holds             CASCADE;
DROP TABLE IF EXISTS gdpr_requests           CASCADE;
DROP TABLE IF EXISTS data_retention_policies CASCADE;
DROP TABLE IF EXISTS audit_log               CASCADE;

-- +goose StatementEnd
