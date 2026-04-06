-- ============================================================
-- services/auth/internal/postgres/migrations/034_fix_025_bugs.sql
-- Scope: auth service database only — independent migration sequence
--
-- Fixes three bugs introduced or missed in 025_add_missing_columns.sql:
--
--   BUG-1 (CRITICAL): prediction_log.tenant_id DEFAULT '' causes silent
--          data loss — any insert without explicit tenant_id gets ''
--          which no RLS policy allows, making the row invisible to all.
--          Fix: change DEFAULT to 'system'.
--
--   BUG-2 (HIGH): usage_records UNIQUE constraint on nullable
--          subscription_id does not prevent duplicates when
--          subscription_id IS NULL because NULL != NULL in PostgreSQL.
--          Fix: add a partial unique index covering the NULL case.
--
--   BUG-3 (MEDIUM): RLS policies on ml_models, feature_values,
--          prediction_log, model_deployments have USING clause only —
--          INSERT and UPDATE are not tenant-scoped.
--          Fix: add WITH CHECK to all four policies.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- BUG-1 (CRITICAL): prediction_log.tenant_id DEFAULT '' → data loss
--   Without this fix, any service that inserts a prediction row
--   without setting tenant_id explicitly writes a row with tenant_id=''
--   which passes NOT NULL but matches no RLS USING clause, making
--   the row permanently invisible to every tenant and super_admin.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE prediction_log
    ALTER COLUMN tenant_id SET DEFAULT 'system';

-- ════════════════════════════════════════════════════════════════════
-- BUG-2 (HIGH): usage_records duplicate billing when subscription_id IS NULL
--   PostgreSQL treats NULL as distinct from every value including NULL,
--   so UNIQUE(tenant_id, subscription_id, metric, period_start, period_end)
--   does not block duplicate rows when subscription_id IS NULL.
--   A partial unique index covering the NULL case closes this gap.
-- ════════════════════════════════════════════════════════════════════
CREATE UNIQUE INDEX IF NOT EXISTS uq_usage_records_no_subscription
    ON usage_records (tenant_id, metric, period_start, period_end)
    WHERE subscription_id IS NULL;

-- ════════════════════════════════════════════════════════════════════
-- BUG-3 (MEDIUM): RLS policies missing WITH CHECK — USING clause only
--   protects SELECT/UPDATE-filter/DELETE-filter. Without WITH CHECK,
--   a tenant can INSERT or UPDATE a row with a foreign tenant_id,
--   bypassing tenant isolation on writes.
--   Fix: drop and recreate each tenant isolation policy with WITH CHECK.
-- ════════════════════════════════════════════════════════════════════

-- ── ml_models ────────────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_ml_models ON ml_models;
CREATE POLICY tenant_isolation_ml_models ON ml_models
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

-- ── feature_values ───────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_feature_values ON feature_values;
CREATE POLICY tenant_isolation_feature_values ON feature_values
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

-- ── prediction_log ───────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_prediction_log ON prediction_log;
CREATE POLICY tenant_isolation_prediction_log ON prediction_log
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    )
    WITH CHECK (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    );

-- ── model_deployments ────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_model_deployments ON model_deployments;
CREATE POLICY tenant_isolation_model_deployments ON model_deployments
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- ── Reverse BUG-3: restore USING-only policies ───────────────────────
DROP POLICY IF EXISTS tenant_isolation_model_deployments ON model_deployments;
CREATE POLICY tenant_isolation_model_deployments ON model_deployments
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    );

DROP POLICY IF EXISTS tenant_isolation_prediction_log ON prediction_log;
CREATE POLICY tenant_isolation_prediction_log ON prediction_log
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    );

DROP POLICY IF EXISTS tenant_isolation_feature_values ON feature_values;
CREATE POLICY tenant_isolation_feature_values ON feature_values
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    );

DROP POLICY IF EXISTS tenant_isolation_ml_models ON ml_models;
CREATE POLICY tenant_isolation_ml_models ON ml_models
    USING (
        tenant_id = 'system'
        OR (
            tenant_id = current_setting('app.tenant_id', true)::text
            AND current_setting('app.tenant_id', true) != ''
        )
    );

-- ── Reverse BUG-2: drop partial unique index ─────────────────────────
DROP INDEX IF EXISTS uq_usage_records_no_subscription;

-- ── Reverse BUG-1: restore original DEFAULT '' ───────────────────────
ALTER TABLE prediction_log
    ALTER COLUMN tenant_id SET DEFAULT '';

-- +goose StatementEnd
