-- ============================================================
-- services/auth/internal/postgres/migrations/018_tenants_extend.sql
-- Scope: auth service database only — independent migration sequence
-- ============================================================
-- +goose Up
-- +goose StatementBegin

-- إضافة أعمدة جديدة لجدول tenants
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS custom_domain TEXT,
    ADD COLUMN IF NOT EXISTS branding JSONB NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS limits JSONB NOT NULL DEFAULT '{"rate_limit":1000,"storage_gb":10,"max_users":10}',
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active',
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS created_by TEXT,
    ADD COLUMN IF NOT EXISTS updated_by TEXT;

-- قيود التحقق
-- UNIQUE constraint with WHERE must be an index, not ALTER TABLE constraint
CREATE UNIQUE INDEX IF NOT EXISTS uq_tenants_custom_domain ON tenants(custom_domain) WHERE custom_domain IS NOT NULL;

-- فهرس للبحث السريع حسب الحالة والمجال المخصص
CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants(status);
CREATE INDEX IF NOT EXISTS idx_tenants_custom_domain ON tenants(custom_domain) WHERE custom_domain IS NOT NULL;

-- إنشاء جدول سجل إجراءات المستأجرين (audit)
CREATE TABLE IF NOT EXISTS tenant_audit_log (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT NOT NULL REFERENCES tenants(id),
    action         TEXT NOT NULL,
    performed_by   TEXT,
    details        JSONB,
    performed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tenant_audit_tenant ON tenant_audit_log(tenant_id, performed_at);

-- +goose StatementEnd
-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS tenant_audit_log CASCADE;
DROP INDEX IF EXISTS uq_tenants_custom_domain;
DROP INDEX IF EXISTS idx_tenants_custom_domain;
DROP INDEX IF EXISTS idx_tenants_status;
ALTER TABLE tenants DROP COLUMN IF EXISTS custom_domain;
ALTER TABLE tenants DROP COLUMN IF EXISTS branding;
ALTER TABLE tenants DROP COLUMN IF EXISTS limits;
ALTER TABLE tenants DROP COLUMN IF EXISTS status;
ALTER TABLE tenants DROP COLUMN IF EXISTS deleted_at;
ALTER TABLE tenants DROP COLUMN IF EXISTS created_by;
ALTER TABLE tenants DROP COLUMN IF EXISTS updated_by;
-- +goose StatementEnd
