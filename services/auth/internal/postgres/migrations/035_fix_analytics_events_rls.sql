-- ============================================================
-- services/auth/internal/postgres/migrations/035_fix_analytics_events_rls.sql
-- Scope: auth service database only — independent migration sequence
--
-- Fix:
--   F-SQL34-REGRESSION: migration 029_partition_analytics_events.sql
--   recreated analytics_events as a partitioned table without
--   ENABLE ROW LEVEL SECURITY or any policy, undoing the fix
--   applied by 024_fix_rls_policies.sql.
--
--   Impact: all analytics_events rows visible to all tenants since
--   029 was applied. This migration re-enables RLS on the new
--   partitioned table — RLS on a partitioned parent propagates
--   automatically to all existing and future partitions.
--
--   Other analytics tables (analytics_user_journeys, analytics_funnels,
--   analytics_funnel_results, analytics_cohorts, analytics_retention)
--   were NOT touched by 029 and remain protected by 024.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- Re-enable RLS on analytics_events partitioned table.
-- PostgreSQL propagates RLS to all partitions automatically when
-- set on the parent table.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE analytics_events ENABLE ROW LEVEL SECURITY;

-- ════════════════════════════════════════════════════════════════════
-- Tenant isolation policy — restores exact logic from 024 and adds
-- WITH CHECK to prevent cross-tenant writes (INSERT/UPDATE).
-- Empty tenant_id is rejected to prevent data leaks via misconfigured
-- sessions.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS tenant_isolation_analytics_events ON analytics_events;
CREATE POLICY tenant_isolation_analytics_events ON analytics_events
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

-- ════════════════════════════════════════════════════════════════════
-- Super-admin bypass — platform operations require full visibility
-- across all tenant partitions.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS super_admin_all ON analytics_events;
CREATE POLICY super_admin_all ON analytics_events
    USING (current_setting('app.user_role', true) = 'super_admin')
    WITH CHECK (current_setting('app.user_role', true) = 'super_admin');

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Reverse: remove policies and disable RLS — restores broken state
-- from 029 (intentionally unsafe, matches pre-Up state for rollback)
DROP POLICY IF EXISTS super_admin_all                    ON analytics_events;
DROP POLICY IF EXISTS tenant_isolation_analytics_events  ON analytics_events;
ALTER TABLE analytics_events DISABLE ROW LEVEL SECURITY;

-- +goose StatementEnd
