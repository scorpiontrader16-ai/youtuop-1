-- ============================================================
-- services/auth/internal/postgres/migrations/004_tenants.sql
-- Scope: auth service database only — independent migration sequence
-- Global numbering reflects creation order across all services
--
-- Creates tenants table foundation for multi-tenant architecture.
-- This is duplicated from ingestion/004 because each service has
-- independent database in production.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ── 1. Tenants Table ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tenants (
    id            TEXT        PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
    name          TEXT        NOT NULL,
    slug          TEXT        NOT NULL UNIQUE,
    status        TEXT        NOT NULL DEFAULT 'active',
    plan          TEXT        NOT NULL DEFAULT 'basic',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_tenant_status CHECK (status IN ('active', 'suspended', 'deleted')),
    CONSTRAINT chk_tenant_plan   CHECK (plan   IN ('basic', 'pro', 'business', 'enterprise')),
    CONSTRAINT chk_tenant_slug   CHECK (slug ~ '^[a-z0-9-]+$')
);

CREATE INDEX IF NOT EXISTS idx_tenants_slug   ON tenants (slug);
CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants (status);

COMMENT ON TABLE tenants IS 
    'Multi-tenant foundation. Each tenant is isolated via RLS on all tenant-scoped tables.';

COMMENT ON COLUMN tenants.slug IS 
    'URL-safe unique identifier for tenant (e.g., acme-corp). Used in subdomain routing.';

-- ── 2. updated_at Trigger Function ──────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_updated_at() IS
    'Auto-updates updated_at column on row modification. Used by triggers.';

CREATE TRIGGER trg_tenants_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── 3. Seed System Tenant ────────────────────────────────────
-- System tenant for platform-owned resources (default models, etc.)
INSERT INTO tenants (id, name, slug, status, plan)
VALUES ('system', 'System', 'system', 'active', 'enterprise')
ON CONFLICT (id) DO NOTHING;

COMMENT ON COLUMN tenants.id IS
    'Tenant UUID. Special value "system" reserved for platform-owned resources.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TRIGGER IF EXISTS trg_tenants_updated_at ON tenants;
DROP FUNCTION IF EXISTS update_updated_at();
DROP TABLE IF EXISTS tenants CASCADE;

-- +goose StatementEnd
