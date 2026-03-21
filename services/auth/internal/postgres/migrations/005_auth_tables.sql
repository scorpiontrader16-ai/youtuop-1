-- ============================================================
-- 005_auth_tables.sql
-- M8 Auth & Identity + M10 RBAC
-- يبني فوق tenants table الموجودة في 004
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ── 1. Users ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id             TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    email          TEXT        NOT NULL UNIQUE,
    email_verified BOOLEAN     NOT NULL DEFAULT FALSE,
    keycloak_id    TEXT        UNIQUE,
    first_name     TEXT,
    last_name      TEXT,
    avatar_url     TEXT,
    status         TEXT        NOT NULL DEFAULT 'active',
    failed_logins  INTEGER     NOT NULL DEFAULT 0,
    locked_until   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at  TIMESTAMPTZ,
    CONSTRAINT chk_users_status CHECK (status IN ('active', 'inactive', 'banned')),
    CONSTRAINT chk_users_email  CHECK (email <> '')
);

CREATE INDEX IF NOT EXISTS idx_users_email       ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_keycloak_id ON users (keycloak_id) WHERE keycloak_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_status      ON users (status);

-- ── 2. User ↔ Tenant Membership (M9) ───────────────────────
CREATE TABLE IF NOT EXISTS user_tenants (
    user_id    TEXT        NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    tenant_id  TEXT        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    role       TEXT        NOT NULL DEFAULT 'viewer',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, tenant_id),
    CONSTRAINT chk_user_tenants_role CHECK (
        role IN ('super_admin', 'tenant_admin', 'manager', 'analyst', 'viewer', 'api_user')
    )
);

CREATE INDEX IF NOT EXISTS idx_user_tenants_tenant ON user_tenants (tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_tenants_role   ON user_tenants (tenant_id, role);

-- ── 3. Sessions (M8) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sessions (
    id                 TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    user_id            TEXT        NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    tenant_id          TEXT        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    device_fingerprint TEXT,
    ip_address         TEXT,
    user_agent         TEXT,
    last_active_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at         TIMESTAMPTZ NOT NULL,
    revoked            BOOLEAN     NOT NULL DEFAULT FALSE,
    revoked_at         TIMESTAMPTZ,
    revoke_reason      TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_sessions_expires CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS idx_sessions_user   ON sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_tenant ON sessions (tenant_id);
CREATE INDEX IF NOT EXISTS idx_sessions_active ON sessions (expires_at) WHERE NOT revoked;

-- ── 4. Refresh Tokens (M8) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id         TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    session_id TEXT        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    token_hash TEXT        NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used       BOOLEAN     NOT NULL DEFAULT FALSE,
    used_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens (token_hash);

-- ── 5. MFA Credentials (M8) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS mfa_credentials (
    id         TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    user_id    TEXT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type       TEXT        NOT NULL,
    secret     TEXT,
    phone      TEXT,
    verified   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, type),
    CONSTRAINT chk_mfa_type CHECK (type IN ('totp', 'sms'))
);

-- ── 6. API Keys (M8) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS api_keys (
    id         TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    user_id    TEXT        NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    tenant_id  TEXT        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    key_prefix TEXT        NOT NULL,
    key_hash   TEXT        NOT NULL UNIQUE,
    name       TEXT        NOT NULL,
    scopes     TEXT[]      NOT NULL DEFAULT '{}',
    expires_at TIMESTAMPTZ,
    last_used  TIMESTAMPTZ,
    revoked    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_api_keys_prefix CHECK (key_prefix <> ''),
    CONSTRAINT chk_api_keys_name   CHECK (name <> '')
);

CREATE INDEX IF NOT EXISTS idx_api_keys_hash   ON api_keys (key_hash);
CREATE INDEX IF NOT EXISTS idx_api_keys_tenant ON api_keys (tenant_id) WHERE NOT revoked;

-- ── 7. Roles (M10) ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS roles (
    id          TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    tenant_id   TEXT        REFERENCES tenants(id) ON DELETE CASCADE,
    name        TEXT        NOT NULL,
    description TEXT,
    is_system   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (tenant_id, name)
);

-- ── 8. Permissions (M10) ────────────────────────────────────
CREATE TABLE IF NOT EXISTS permissions (
    id       TEXT PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    resource TEXT NOT NULL,
    action   TEXT NOT NULL,
    UNIQUE (resource, action)
);

-- ── 9. Role ↔ Permission (M10) ──────────────────────────────
CREATE TABLE IF NOT EXISTS role_permissions (
    role_id       TEXT NOT NULL REFERENCES roles(id)       ON DELETE CASCADE,
    permission_id TEXT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

-- ── 10. RLS ─────────────────────────────────────────────────
ALTER TABLE sessions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_keys     ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_tenants ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_sessions
    ON sessions
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

CREATE POLICY tenant_isolation_api_keys
    ON api_keys
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

CREATE POLICY tenant_isolation_user_tenants
    ON user_tenants
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

-- ── 11. updated_at trigger — الـ function موجودة من 004 ─────
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── 12. Seed: System Roles ───────────────────────────────────
INSERT INTO roles (name, description, is_system) VALUES
    ('super_admin',  'Full platform access',               TRUE),
    ('tenant_admin', 'Full tenant management',             TRUE),
    ('manager',      'User management within tenant',      TRUE),
    ('analyst',      'Analytics and reporting',            TRUE),
    ('viewer',       'Read-only access',                   TRUE),
    ('api_user',     'API access only',                    TRUE)
ON CONFLICT DO NOTHING;

-- ── 13. Seed: Permissions ────────────────────────────────────
INSERT INTO permissions (resource, action) VALUES
    ('markets',   'read'),   ('markets',   'write'),  ('markets',   'stream'),
    ('analytics', 'read'),   ('analytics', 'export'), ('analytics', 'backtest'),
    ('agents',    'read'),   ('agents',    'write'),   ('agents',    'execute'), ('agents', 'delete'),
    ('users',     'read'),   ('users',     'write'),   ('users',     'delete'),
    ('billing',   'read'),   ('billing',   'write'),
    ('audit',     'read'),
    ('system',    'admin')
ON CONFLICT DO NOTHING;

-- ── 14. Seed: Role-Permission Mapping ───────────────────────
-- super_admin: كل حاجة
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'super_admin' AND r.is_system = TRUE
ON CONFLICT DO NOTHING;

-- tenant_admin: كل حاجة ماعدا system:admin
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'tenant_admin' AND r.is_system = TRUE
  AND NOT (p.resource = 'system' AND p.action = 'admin')
ON CONFLICT DO NOTHING;

-- manager: users read/write + read everything
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'manager' AND r.is_system = TRUE
  AND (
    (p.resource = 'users'     AND p.action IN ('read', 'write'))
    OR (p.resource IN ('markets', 'analytics', 'agents') AND p.action = 'read')
  )
ON CONFLICT DO NOTHING;

-- analyst: markets + analytics + agents execute
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'analyst' AND r.is_system = TRUE
  AND (
    (p.resource = 'markets'   AND p.action IN ('read', 'stream'))
    OR (p.resource = 'analytics' AND p.action IN ('read', 'export', 'backtest'))
    OR (p.resource = 'agents'    AND p.action IN ('read', 'execute'))
  )
ON CONFLICT DO NOTHING;

-- viewer: read only
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'viewer' AND r.is_system = TRUE
  AND p.action = 'read'
ON CONFLICT DO NOTHING;

-- api_user: markets read/stream + agents execute
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id FROM roles r, permissions p
WHERE r.name = 'api_user' AND r.is_system = TRUE
  AND (
    (p.resource = 'markets' AND p.action IN ('read', 'stream'))
    OR (p.resource = 'agents' AND p.action = 'execute')
  )
ON CONFLICT DO NOTHING;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;

DROP POLICY IF EXISTS tenant_isolation_user_tenants ON user_tenants;
DROP POLICY IF EXISTS tenant_isolation_api_keys     ON api_keys;
DROP POLICY IF EXISTS tenant_isolation_sessions     ON sessions;

ALTER TABLE user_tenants DISABLE ROW LEVEL SECURITY;
ALTER TABLE api_keys     DISABLE ROW LEVEL SECURITY;
ALTER TABLE sessions     DISABLE ROW LEVEL SECURITY;

DROP TABLE IF EXISTS role_permissions  CASCADE;
DROP TABLE IF EXISTS permissions       CASCADE;
DROP TABLE IF EXISTS roles             CASCADE;
DROP TABLE IF EXISTS api_keys          CASCADE;
DROP TABLE IF EXISTS mfa_credentials   CASCADE;
DROP TABLE IF EXISTS refresh_tokens    CASCADE;
DROP TABLE IF EXISTS sessions          CASCADE;
DROP TABLE IF EXISTS user_tenants      CASCADE;
DROP TABLE IF EXISTS users             CASCADE;

-- +goose StatementEnd
