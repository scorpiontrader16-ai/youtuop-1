-- ============================================================
-- services/auth/internal/postgres/migrations/030_add_missing_columns_and_rls.sql
-- Scope: auth service database only — independent migration sequence
-- Global numbering reflects creation order across all services
--
-- Fixes:
--   F-SQL08 HIGH:     api_keys without revoked_at column
--   F-SQL10 HIGH:     usage_records without UNIQUE constraint → duplicate billing
--   F-SQL16 CRITICAL: ml_models without tenant_id → all tenants see all models
--   F-SQL17 CRITICAL: feature_values without tenant_id → cross-tenant ML data leak
--   F-SQL18 CRITICAL: prediction_log.tenant_id nullable without RLS
--   F-SQL23 HIGH:     model_deployments without tenant_id
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- F-SQL08: api_keys without revoked_at column.
--          API keys can be created and deleted but cannot be revoked
--          (soft delete). This means deleted keys cannot be audited
--          or reinstated. Add revoked_at for soft revocation.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE api_keys
    ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_api_keys_active
    ON api_keys (tenant_id, revoked_at)
    WHERE revoked_at IS NULL;

-- ════════════════════════════════════════════════════════════════════
-- F-SQL10: usage_records without UNIQUE constraint.
--          Same usage period can be recorded multiple times causing
--          duplicate billing. Add composite UNIQUE constraint.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE usage_records
    ADD CONSTRAINT uq_usage_records_period
    UNIQUE (tenant_id, subscription_id, metric, period_start, period_end);

-- ════════════════════════════════════════════════════════════════════
-- F-SQL16: ml_models without tenant_id.
--          All ML models are visible to all tenants — critical security
--          issue. Add tenant_id column, backfill with 'system' for
--          existing rows, then enable RLS.
-- ════════════════════════════════════════════════════════════════════

-- Step 1: Add column (nullable initially for existing data)
ALTER TABLE ml_models
    ADD COLUMN IF NOT EXISTS tenant_id TEXT REFERENCES tenants(id) ON DELETE CASCADE;

-- Step 2: Backfill existing rows with 'system' tenant
--         (In production: replace 'system' with actual system tenant ID)
UPDATE ml_models
    SET tenant_id = 'system'
    WHERE tenant_id IS NULL;

-- Step 3: Make column NOT NULL
ALTER TABLE ml_models
    ALTER COLUMN tenant_id SET NOT NULL;

-- Step 4: Add index for RLS performance
CREATE INDEX IF NOT EXISTS idx_ml_models_tenant
    ON ml_models (tenant_id);

-- Step 5: Enable RLS
ALTER TABLE ml_models ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_ml_models
    ON ml_models
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

-- ════════════════════════════════════════════════════════════════════
-- F-SQL17: feature_values without tenant_id.
--          Feature store data is shared across tenants — ML training
--          on cross-tenant data. Add tenant_id + RLS.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE feature_values
    ADD COLUMN IF NOT EXISTS tenant_id TEXT REFERENCES tenants(id) ON DELETE CASCADE;

UPDATE feature_values
    SET tenant_id = 'system'
    WHERE tenant_id IS NULL;

ALTER TABLE feature_values
    ALTER COLUMN tenant_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_feature_values_tenant
    ON feature_values (tenant_id);

ALTER TABLE feature_values ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_feature_values
    ON feature_values
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

-- ════════════════════════════════════════════════════════════════════
-- F-SQL18: prediction_log.tenant_id nullable without RLS.
--          Column exists but is nullable, allowing NULL bypass of
--          any future RLS policy. Set NOT NULL + add RLS.
-- ════════════════════════════════════════════════════════════════════

-- Backfill NULL values
UPDATE prediction_log
    SET tenant_id = 'system'
    WHERE tenant_id IS NULL;

-- Set NOT NULL
ALTER TABLE prediction_log
    ALTER COLUMN tenant_id SET NOT NULL;

-- Add FK constraint (may not exist in original migration)
ALTER TABLE prediction_log
    ADD CONSTRAINT fk_prediction_log_tenant
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE;

-- Enable RLS (indexes already exist from 012)
ALTER TABLE prediction_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_prediction_log
    ON prediction_log
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

-- ════════════════════════════════════════════════════════════════════
-- F-SQL23: model_deployments without tenant_id.
--          Deployment records are not isolated — any tenant can see
--          deployment status of other tenants' models. Add tenant_id + RLS.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE model_deployments
    ADD COLUMN IF NOT EXISTS tenant_id TEXT REFERENCES tenants(id) ON DELETE CASCADE;

UPDATE model_deployments
    SET tenant_id = 'system'
    WHERE tenant_id IS NULL;

ALTER TABLE model_deployments
    ALTER COLUMN tenant_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_model_deployments_tenant
    ON model_deployments (tenant_id);

ALTER TABLE model_deployments ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_model_deployments
    ON model_deployments
    USING (
        current_setting('app.tenant_id', true) = ''
        OR tenant_id = current_setting('app.tenant_id', true)
    );

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- ── Reverse F-SQL23 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_model_deployments ON model_deployments;
ALTER TABLE model_deployments DISABLE ROW LEVEL SECURITY;
DROP INDEX IF EXISTS idx_model_deployments_tenant;
ALTER TABLE model_deployments DROP COLUMN IF EXISTS tenant_id;

-- ── Reverse F-SQL18 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_prediction_log ON prediction_log;
ALTER TABLE prediction_log DISABLE ROW LEVEL SECURITY;
ALTER TABLE prediction_log DROP CONSTRAINT IF EXISTS fk_prediction_log_tenant;
ALTER TABLE prediction_log ALTER COLUMN tenant_id DROP NOT NULL;

-- ── Reverse F-SQL17 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_feature_values ON feature_values;
ALTER TABLE feature_values DISABLE ROW LEVEL SECURITY;
DROP INDEX IF EXISTS idx_feature_values_tenant;
ALTER TABLE feature_values DROP COLUMN IF EXISTS tenant_id;

-- ── Reverse F-SQL16 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_ml_models ON ml_models;
ALTER TABLE ml_models DISABLE ROW LEVEL SECURITY;
DROP INDEX IF EXISTS idx_ml_models_tenant;
ALTER TABLE ml_models DROP COLUMN IF EXISTS tenant_id;

-- ── Reverse F-SQL10 ──────────────────────────────────────────────────
ALTER TABLE usage_records DROP CONSTRAINT IF EXISTS uq_usage_records_period;

-- ── Reverse F-SQL08 ──────────────────────────────────────────────────
DROP INDEX IF EXISTS idx_api_keys_active;
ALTER TABLE api_keys DROP COLUMN IF EXISTS revoked_at;

-- +goose StatementEnd
