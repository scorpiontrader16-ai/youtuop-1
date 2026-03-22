-- ============================================================
-- 009_control_plane.sql
-- M15 Control Plane — system config + kill switches
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ── 1. System Configuration (dynamic, no restart needed) ────
CREATE TABLE IF NOT EXISTS system_config (
    key         TEXT        PRIMARY KEY,
    value       JSONB       NOT NULL,
    description TEXT,
    updated_by  TEXT        REFERENCES users(id),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 2. Kill Switches ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kill_switches (
    id          TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    name        TEXT        NOT NULL UNIQUE,
    description TEXT,
    enabled     BOOLEAN     NOT NULL DEFAULT FALSE,
    scope       TEXT        NOT NULL DEFAULT 'global',
    scope_id    TEXT,
    enabled_by  TEXT        REFERENCES users(id),
    enabled_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_kill_switch_scope CHECK (
        scope IN ('global', 'tenant', 'service')
    )
);

-- ── 3. Maintenance Mode ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS maintenance_windows (
    id           TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    title        TEXT        NOT NULL,
    message      TEXT        NOT NULL,
    starts_at    TIMESTAMPTZ NOT NULL,
    ends_at      TIMESTAMPTZ,
    active       BOOLEAN     NOT NULL DEFAULT FALSE,
    created_by   TEXT        REFERENCES users(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_maintenance_dates CHECK (ends_at IS NULL OR ends_at > starts_at)
);

-- ── 4. Announcement Banners ──────────────────────────────────
CREATE TABLE IF NOT EXISTS announcements (
    id          TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    title       TEXT        NOT NULL,
    message     TEXT        NOT NULL,
    type        TEXT        NOT NULL DEFAULT 'info',
    active      BOOLEAN     NOT NULL DEFAULT TRUE,
    starts_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at     TIMESTAMPTZ,
    created_by  TEXT        REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_announcement_type CHECK (
        type IN ('info', 'warning', 'critical')
    )
);

CREATE INDEX IF NOT EXISTS idx_announcements_active
    ON announcements (active, starts_at)
    WHERE active = TRUE;

-- ── 5. Impersonation Log ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS impersonation_log (
    id              BIGSERIAL   PRIMARY KEY,
    admin_user_id   TEXT        NOT NULL REFERENCES users(id),
    target_user_id  TEXT        NOT NULL REFERENCES users(id),
    tenant_id       TEXT        REFERENCES tenants(id),
    reason          TEXT        NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMPTZ,
    ip_address      TEXT
);

CREATE INDEX IF NOT EXISTS idx_impersonation_admin
    ON impersonation_log (admin_user_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_impersonation_target
    ON impersonation_log (target_user_id, started_at DESC);

-- ── 6. WriteAudit Function (يُستدعى من كل service) ──────────
-- helper function تكتب في audit_log بشكل آمن
CREATE OR REPLACE FUNCTION write_audit(
    p_tenant_id   TEXT,
    p_user_id     TEXT,
    p_action      TEXT,
    p_resource    TEXT,
    p_resource_id TEXT DEFAULT NULL,
    p_old_data    JSONB DEFAULT NULL,
    p_new_data    JSONB DEFAULT NULL,
    p_ip_address  TEXT DEFAULT NULL,
    p_trace_id    TEXT DEFAULT NULL,
    p_status      TEXT DEFAULT 'success',
    p_error       TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (
        tenant_id, user_id, action, resource, resource_id,
        old_data, new_data, ip_address, trace_id, status, error
    ) VALUES (
        p_tenant_id, p_user_id, p_action, p_resource, p_resource_id,
        p_old_data, p_new_data, p_ip_address, p_trace_id, p_status, p_error
    );
EXCEPTION WHEN OTHERS THEN
    -- Audit لازم ميفشلش ويأثر على الـ main operation
    -- بنسجل الـ error ونكمل
    RAISE WARNING 'write_audit failed: %', SQLERRM;
END;
$$;

-- ── 7. Seed: Default System Config ───────────────────────────
INSERT INTO system_config (key, value, description) VALUES
    ('platform.maintenance_mode',     'false',                    'Global maintenance mode flag'),
    ('platform.max_tenants',          '1000',                     'Maximum number of active tenants'),
    ('platform.default_trial_days',   '14',                       'Default trial period in days'),
    ('platform.rate_limit_enabled',   'true',                     'Enable/disable rate limiting globally'),
    ('platform.new_signups_enabled',  'true',                     'Allow new tenant signups'),
    ('billing.stripe_mode',           '"live"',                   'Stripe mode: live or test'),
    ('notifications.email_enabled',   'true',                     'Enable email notifications globally'),
    ('security.mfa_required',         'false',                    'Require MFA for all users')
ON CONFLICT (key) DO NOTHING;

-- ── 8. Seed: Default Kill Switches ───────────────────────────
INSERT INTO kill_switches (name, description, enabled, scope) VALUES
    ('ingestion.kafka_consumer',   'Stop consuming from Redpanda',           FALSE, 'service'),
    ('processing.engine',          'Disable Rust processing engine',          FALSE, 'service'),
    ('billing.stripe_webhooks',    'Stop processing Stripe webhooks',         FALSE, 'service'),
    ('notifications.email',        'Stop sending all emails',                 FALSE, 'service'),
    ('auth.new_logins',            'Prevent new login attempts',              FALSE, 'global'),
    ('auth.new_signups',           'Prevent new tenant signups',              FALSE, 'global'),
    ('api.write_operations',       'Disable all write operations (read-only)', FALSE, 'global')
ON CONFLICT (name) DO NOTHING;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP FUNCTION IF EXISTS write_audit(TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,JSONB,TEXT,TEXT,TEXT,TEXT);

DROP TABLE IF EXISTS impersonation_log    CASCADE;
DROP TABLE IF EXISTS announcements        CASCADE;
DROP TABLE IF EXISTS maintenance_windows  CASCADE;
DROP TABLE IF EXISTS kill_switches        CASCADE;
DROP TABLE IF EXISTS system_config        CASCADE;

-- +goose StatementEnd
