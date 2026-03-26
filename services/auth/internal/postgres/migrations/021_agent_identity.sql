-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  services/auth/internal/postgres/migrations/021_agent_identity.sql ║
-- ║  M8 – Agent Identity Foundation                                 ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- +goose Up
-- +goose StatementBegin

-- ── 1. Agents ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agents (
    id              TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    tenant_id       TEXT        NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name            TEXT        NOT NULL,
    agent_type      TEXT        NOT NULL,
    service_account TEXT,
    status          TEXT        NOT NULL DEFAULT 'active',
    created_by      TEXT        REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_agents_name        CHECK (name <> ''),
    CONSTRAINT chk_agents_type        CHECK (agent_type IN ('ml', 'trading', 'analytics', 'notification', 'custom')),
    CONSTRAINT chk_agents_status      CHECK (status IN ('active', 'inactive', 'suspended'))
);

CREATE INDEX IF NOT EXISTS idx_agents_tenant        ON agents (tenant_id);
CREATE INDEX IF NOT EXISTS idx_agents_tenant_status ON agents (tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_agents_created_by    ON agents (created_by) WHERE created_by IS NOT NULL;

-- ── 2. Agent Permissions ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agent_permissions (
    agent_id    TEXT        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    permission  TEXT        NOT NULL,
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    granted_by  TEXT        REFERENCES users(id) ON DELETE SET NULL,
    PRIMARY KEY (agent_id, permission),
    CONSTRAINT chk_agent_permission_format CHECK (permission ~ '^[a-z_]+:[a-z_]+$')
);

CREATE INDEX IF NOT EXISTS idx_agent_permissions_agent ON agent_permissions (agent_id);

-- ── 3. RLS ───────────────────────────────────────────────────────────
ALTER TABLE agents            ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_agents
    ON agents
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

CREATE POLICY tenant_isolation_agent_permissions
    ON agent_permissions
    USING (
        current_setting('app.tenant_id', true) = ''
        OR agent_id IN (
            SELECT id FROM agents
            WHERE tenant_id = current_setting('app.tenant_id', true)
        )
    );

-- ── 4. updated_at trigger ────────────────────────────────────────────
CREATE TRIGGER trg_agents_updated_at
    BEFORE UPDATE ON agents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TRIGGER IF EXISTS trg_agents_updated_at ON agents;

DROP POLICY IF EXISTS tenant_isolation_agent_permissions ON agent_permissions;
DROP POLICY IF EXISTS tenant_isolation_agents            ON agents;

ALTER TABLE agent_permissions DISABLE ROW LEVEL SECURITY;
ALTER TABLE agents            DISABLE ROW LEVEL SECURITY;

DROP TABLE IF EXISTS agent_permissions CASCADE;
DROP TABLE IF EXISTS agents            CASCADE;

-- +goose StatementEnd
