-- ============================================================
-- services/auth/internal/postgres/migrations/024_fix_rls_policies.sql
-- Scope: auth service database only — independent migration sequence
--
-- Fixes:
--   F-SQL01: users policy USING (true) → tenant-scoped via user_tenants
--   F-SQL02: super_admin_all missing on users/sessions/api_keys/user_roles
--   F-SQL03: billing policies accept empty tenant_id → data leak
--   F-SQL06: SKIPPED — tables don't exist in DB yet
--   F-SQL12: schema_versions has RLS enabled but no policy → blocks goose
--   F-SQL21: background_jobs/cron_jobs have no RLS
--   F-SQL25: flag_evaluations tenant_id nullable + no RLS
--   F-SQL33: search tables have no RLS
--   F-SQL34: analytics tables have no RLS
--   F-SQL40: notification_preferences has no RLS
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- F-SQL01: Fix users policy — USING (true) exposes all users to all
--          tenants. users table has no tenant_id (global, many-to-many
--          via user_tenants). Must scope via EXISTS subquery.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS tenant_isolation_users ON users;
CREATE POLICY tenant_isolation_users ON users
    USING (
        EXISTS (
            SELECT 1 FROM user_tenants ut
            WHERE ut.user_id = users.id
              AND ut.tenant_id = current_setting('app.tenant_id', true)::text
              AND current_setting('app.tenant_id', true) != ''
        )
    );

-- ════════════════════════════════════════════════════════════════════
-- F-SQL02: super_admin bypass missing on all protected tables.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS super_admin_all ON users;
CREATE POLICY super_admin_all ON users
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON user_roles;
CREATE POLICY super_admin_all ON user_roles
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON sessions;
CREATE POLICY super_admin_all ON sessions
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON api_keys;
CREATE POLICY super_admin_all ON api_keys
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON mfa_secrets;
CREATE POLICY super_admin_all ON mfa_secrets
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON password_history;
CREATE POLICY super_admin_all ON password_history
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON account_recovery_tokens;
CREATE POLICY super_admin_all ON account_recovery_tokens
    USING (current_setting('app.user_role', true) = 'super_admin');

-- ════════════════════════════════════════════════════════════════════
-- F-SQL03: Billing policies accept empty tenant_id.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS tenant_isolation_subscriptions ON subscriptions;
CREATE POLICY tenant_isolation_subscriptions ON subscriptions
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS tenant_isolation_invoices ON invoices;
CREATE POLICY tenant_isolation_invoices ON invoices
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS tenant_isolation_usage_records ON usage_records;
CREATE POLICY tenant_isolation_usage_records ON usage_records
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS tenant_isolation_payment_methods ON payment_methods;
CREATE POLICY tenant_isolation_payment_methods ON payment_methods
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS super_admin_all ON subscriptions;
CREATE POLICY super_admin_all ON subscriptions
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON invoices;
CREATE POLICY super_admin_all ON invoices
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON usage_records;
CREATE POLICY super_admin_all ON usage_records
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON payment_methods;
CREATE POLICY super_admin_all ON payment_methods
    USING (current_setting('app.user_role', true) = 'super_admin');

-- ════════════════════════════════════════════════════════════════════
-- F-SQL06: SKIPPED — control-plane tables not created yet
--
-- Original F-SQL06 attempted RLS on:
--   system_config, kill_switches, maintenance_windows,
--   announcements, impersonation_log
--
-- None exist in migrations 004-023. Applying RLS on non-existent
-- tables causes migration failure. This fix is deferred until those
-- tables are created in a future migration.
-- ════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════
-- F-SQL12: schema_versions blocks goose.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE goose_db_version DISABLE ROW LEVEL SECURITY;

-- ════════════════════════════════════════════════════════════════════
-- F-SQL21: background_jobs/cron_jobs have no RLS.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE background_jobs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE background_job_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE cron_jobs           ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_background_jobs ON background_jobs
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_job_logs ON background_job_logs
    USING (
        EXISTS (
            SELECT 1 FROM background_jobs
            WHERE id = job_id
              AND tenant_id = current_setting('app.tenant_id', true)::text
              AND current_setting('app.tenant_id', true) != ''
        )
    );

CREATE POLICY tenant_isolation_cron_jobs ON cron_jobs
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS super_admin_all ON background_jobs;
CREATE POLICY super_admin_all ON background_jobs
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON background_job_logs;
CREATE POLICY super_admin_all ON background_job_logs
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON cron_jobs;
CREATE POLICY super_admin_all ON cron_jobs
    USING (current_setting('app.user_role', true) = 'super_admin');

-- ════════════════════════════════════════════════════════════════════
-- F-SQL25: flag_evaluations.tenant_id nullable.
--
-- SKIPPED: flag_evaluations table not created in migrations 004-023.
-- Table appears in \dt output but was likely created manually or in
-- a different service. Deferred until table creation is in migrations.
-- ════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════
-- F-SQL33: search tables have no RLS.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE search_indices  ENABLE ROW LEVEL SECURITY;
ALTER TABLE search_queries  ENABLE ROW LEVEL SECURITY;
ALTER TABLE search_clicks   ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_search_indices ON search_indices
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_search_queries ON search_queries
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_search_clicks ON search_clicks
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS super_admin_all ON search_indices;
CREATE POLICY super_admin_all ON search_indices
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON search_queries;
CREATE POLICY super_admin_all ON search_queries
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON search_clicks;
CREATE POLICY super_admin_all ON search_clicks
    USING (current_setting('app.user_role', true) = 'super_admin');

-- ════════════════════════════════════════════════════════════════════
-- F-SQL34: analytics tables have no RLS.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE analytics_events         ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_user_journeys  ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_funnels        ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_funnel_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_cohorts        ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_retention      ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_analytics_events ON analytics_events
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_analytics_journeys ON analytics_user_journeys
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_analytics_funnels ON analytics_funnels
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_analytics_cohorts ON analytics_cohorts
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

CREATE POLICY tenant_isolation_funnel_results ON analytics_funnel_results
    USING (
        EXISTS (
            SELECT 1 FROM analytics_funnels f
            WHERE f.id = funnel_id
              AND f.tenant_id = current_setting('app.tenant_id', true)::text
              AND current_setting('app.tenant_id', true) != ''
        )
    );

CREATE POLICY tenant_isolation_retention ON analytics_retention
    USING (
        EXISTS (
            SELECT 1 FROM analytics_cohorts c
            WHERE c.id = cohort_id
              AND c.tenant_id = current_setting('app.tenant_id', true)::text
              AND current_setting('app.tenant_id', true) != ''
        )
    );

DROP POLICY IF EXISTS super_admin_all ON analytics_events;
CREATE POLICY super_admin_all ON analytics_events
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON analytics_user_journeys;
CREATE POLICY super_admin_all ON analytics_user_journeys
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON analytics_funnels;
CREATE POLICY super_admin_all ON analytics_funnels
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON analytics_funnel_results;
CREATE POLICY super_admin_all ON analytics_funnel_results
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON analytics_cohorts;
CREATE POLICY super_admin_all ON analytics_cohorts
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON analytics_retention;
CREATE POLICY super_admin_all ON analytics_retention
    USING (current_setting('app.user_role', true) = 'super_admin');

-- ════════════════════════════════════════════════════════════════════
-- F-SQL40: notification_preferences has no RLS.
--
-- SKIPPED: notification_preferences and notifications not created
-- in migrations 004-023. Deferred until table creation.
-- ════════════════════════════════════════════════════════════════════

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- ── Reverse F-SQL34 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_analytics_events    ON analytics_events;
DROP POLICY IF EXISTS tenant_isolation_analytics_journeys  ON analytics_user_journeys;
DROP POLICY IF EXISTS tenant_isolation_analytics_funnels   ON analytics_funnels;
DROP POLICY IF EXISTS tenant_isolation_funnel_results      ON analytics_funnel_results;
DROP POLICY IF EXISTS tenant_isolation_analytics_cohorts   ON analytics_cohorts;
DROP POLICY IF EXISTS tenant_isolation_retention           ON analytics_retention;
DROP POLICY IF EXISTS super_admin_all ON analytics_events;
DROP POLICY IF EXISTS super_admin_all ON analytics_user_journeys;
DROP POLICY IF EXISTS super_admin_all ON analytics_funnels;
DROP POLICY IF EXISTS super_admin_all ON analytics_funnel_results;
DROP POLICY IF EXISTS super_admin_all ON analytics_cohorts;
DROP POLICY IF EXISTS super_admin_all ON analytics_retention;
ALTER TABLE analytics_events         DISABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_user_journeys  DISABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_funnels        DISABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_funnel_results DISABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_cohorts        DISABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_retention      DISABLE ROW LEVEL SECURITY;

-- ── Reverse F-SQL33 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_search_indices ON search_indices;
DROP POLICY IF EXISTS tenant_isolation_search_queries ON search_queries;
DROP POLICY IF EXISTS tenant_isolation_search_clicks  ON search_clicks;
DROP POLICY IF EXISTS super_admin_all ON search_indices;
DROP POLICY IF EXISTS super_admin_all ON search_queries;
DROP POLICY IF EXISTS super_admin_all ON search_clicks;
ALTER TABLE search_indices  DISABLE ROW LEVEL SECURITY;
ALTER TABLE search_queries  DISABLE ROW LEVEL SECURITY;
ALTER TABLE search_clicks   DISABLE ROW LEVEL SECURITY;

-- ── Reverse F-SQL21 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_background_jobs ON background_jobs;
DROP POLICY IF EXISTS tenant_isolation_job_logs        ON background_job_logs;
DROP POLICY IF EXISTS tenant_isolation_cron_jobs       ON cron_jobs;
DROP POLICY IF EXISTS super_admin_all ON background_jobs;
DROP POLICY IF EXISTS super_admin_all ON background_job_logs;
DROP POLICY IF EXISTS super_admin_all ON cron_jobs;
ALTER TABLE background_jobs     DISABLE ROW LEVEL SECURITY;
ALTER TABLE background_job_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE cron_jobs           DISABLE ROW LEVEL SECURITY;

-- ── Reverse F-SQL12 ──────────────────────────────────────────────────
ALTER TABLE goose_db_version ENABLE ROW LEVEL SECURITY;

-- ── Reverse F-SQL03 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_subscriptions   ON subscriptions;
DROP POLICY IF EXISTS tenant_isolation_invoices        ON invoices;
DROP POLICY IF EXISTS tenant_isolation_usage_records   ON usage_records;
DROP POLICY IF EXISTS tenant_isolation_payment_methods ON payment_methods;
DROP POLICY IF EXISTS super_admin_all ON subscriptions;
DROP POLICY IF EXISTS super_admin_all ON invoices;
DROP POLICY IF EXISTS super_admin_all ON usage_records;
DROP POLICY IF EXISTS super_admin_all ON payment_methods;
CREATE POLICY tenant_isolation_subscriptions ON subscriptions
    USING (current_setting('app.tenant_id', true) = '' OR tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY tenant_isolation_invoices ON invoices
    USING (current_setting('app.tenant_id', true) = '' OR tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY tenant_isolation_usage_records ON usage_records
    USING (current_setting('app.tenant_id', true) = '' OR tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY tenant_isolation_payment_methods ON payment_methods
    USING (current_setting('app.tenant_id', true) = '' OR tenant_id = current_setting('app.tenant_id', true));

-- ── Reverse F-SQL02 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS super_admin_all ON users;
DROP POLICY IF EXISTS super_admin_all ON user_roles;
DROP POLICY IF EXISTS super_admin_all ON sessions;
DROP POLICY IF EXISTS super_admin_all ON api_keys;
DROP POLICY IF EXISTS super_admin_all ON mfa_secrets;
DROP POLICY IF EXISTS super_admin_all ON password_history;
DROP POLICY IF EXISTS super_admin_all ON account_recovery_tokens;

-- ── Reverse F-SQL01 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_users ON users;
CREATE POLICY tenant_isolation_users ON users USING (true);

-- +goose StatementEnd
