-- ============================================================
-- services/auth/internal/postgres/migrations/024_fix_rls_policies.sql
-- Scope: auth service database only — independent migration sequence
-- Global numbering reflects creation order across all services
--
-- Fixes:
--   F-SQL01: users policy USING (true) → tenant-scoped
--   F-SQL02: super_admin_all missing on users/sessions/api_keys/user_roles
--   F-SQL03: billing policies accept empty tenant_id → data leak
--   F-SQL06: control-plane tables have no RLS at all
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
--          tenants. Must scope to tenant_id.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS tenant_isolation_users ON users;
CREATE POLICY tenant_isolation_users ON users
    USING (tenant_id = current_setting('app.tenant_id', true)::text);

-- ════════════════════════════════════════════════════════════════════
-- F-SQL02: super_admin bypass missing on all protected tables.
--          Without this, super_admin cannot manage users/sessions/
--          api_keys across tenants — breaks admin operations.
-- ════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS super_admin_all ON users;
CREATE POLICY super_admin_all ON users
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON user_roles;
CREATE POLICY super_admin_all ON user_roles
    USING (current_setting('app.user_role', true) = 'super_admin');

DROP POLICY IF EXISTS super_admin_all ON active_sessions;
CREATE POLICY super_admin_all ON active_sessions
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
-- F-SQL03: Billing policies accept empty tenant_id — any connection
--          with unset app.tenant_id sees ALL billing data.
--          Fix: require tenant_id to be non-empty.
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
-- F-SQL06: control-plane tables (system_config, kill_switches,
--          maintenance_windows, announcements, impersonation_log)
--          have no RLS at all — any tenant connection can read/modify
--          platform-wide configuration.
--          These are service-account-only tables: only super_admin
--          or platform service role may access them.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE system_config         ENABLE ROW LEVEL SECURITY;
ALTER TABLE kill_switches         ENABLE ROW LEVEL SECURITY;
ALTER TABLE maintenance_windows   ENABLE ROW LEVEL SECURITY;
ALTER TABLE announcements         ENABLE ROW LEVEL SECURITY;
ALTER TABLE impersonation_log     ENABLE ROW LEVEL SECURITY;

CREATE POLICY super_admin_only ON system_config
    USING (current_setting('app.user_role', true) = 'super_admin');

CREATE POLICY super_admin_only ON kill_switches
    USING (current_setting('app.user_role', true) = 'super_admin');

CREATE POLICY super_admin_only ON maintenance_windows
    USING (current_setting('app.user_role', true) = 'super_admin');

-- Announcements readable by all authenticated sessions (public notices)
-- but only writable by super_admin — enforced at application layer via GRANT
CREATE POLICY read_active_announcements ON announcements
    USING (
        active = TRUE
        OR current_setting('app.user_role', true) = 'super_admin'
    );

-- impersonation_log: super_admin reads all; target user reads their own records
CREATE POLICY super_admin_impersonation ON impersonation_log
    USING (current_setting('app.user_role', true) = 'super_admin');

CREATE POLICY self_impersonation_view ON impersonation_log
    USING (target_user_id = current_setting('app.user_id', true)::text);

-- ════════════════════════════════════════════════════════════════════
-- F-SQL12: schema_versions has ENABLE ROW LEVEL SECURITY but no
--          policy — PostgreSQL default-deny blocks ALL access,
--          which means goose migration tool cannot read/write and
--          all future migrations fail.
--          Fix: DISABLE RLS — this is internal infrastructure,
--          not tenant data. Access is controlled by DB role grants.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE schema_versions DISABLE ROW LEVEL SECURITY;

-- ════════════════════════════════════════════════════════════════════
-- F-SQL21: background_jobs and cron_jobs have no RLS.
--          background_job_logs has no tenant_id (child of background_jobs)
--          so tenant isolation is achieved via FK subquery.
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE background_jobs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE background_job_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE cron_jobs           ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_background_jobs ON background_jobs
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

-- background_job_logs has no tenant_id — isolated via parent job ownership
CREATE POLICY tenant_isolation_job_logs ON background_job_logs
    USING (
        job_id IN (
            SELECT id FROM background_jobs
            WHERE tenant_id = current_setting('app.tenant_id', true)::text
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
-- F-SQL25: flag_evaluations.tenant_id is nullable — allows anonymous
--          evaluations to bypass tenant isolation under RLS.
--          Backfill NULLs to sentinel 'system' before adding NOT NULL.
-- ════════════════════════════════════════════════════════════════════
UPDATE flag_evaluations
    SET tenant_id = 'system'
    WHERE tenant_id IS NULL;

ALTER TABLE flag_evaluations
    ALTER COLUMN tenant_id SET NOT NULL,
    ALTER COLUMN tenant_id SET DEFAULT '';

-- Replace partial index (WHERE tenant_id IS NOT NULL) with full index
DROP INDEX IF EXISTS idx_flag_evaluations_tenant;
CREATE INDEX IF NOT EXISTS idx_flag_evaluations_tenant
    ON flag_evaluations (tenant_id, evaluated_at DESC);

ALTER TABLE flag_evaluations ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_flag_evaluations ON flag_evaluations
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS super_admin_all ON flag_evaluations;
CREATE POLICY super_admin_all ON flag_evaluations
    USING (current_setting('app.user_role', true) = 'super_admin');

-- ════════════════════════════════════════════════════════════════════
-- F-SQL33: search_indices, search_queries, search_clicks have no RLS.
--          All three carry tenant_id NOT NULL — direct policy applies.
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
-- F-SQL34: 6 analytics tables have no RLS.
--          analytics_funnel_results and analytics_retention have no
--          direct tenant_id — isolated via parent table EXISTS subquery.
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

-- funnel_results has no tenant_id — scoped through parent funnel
CREATE POLICY tenant_isolation_funnel_results ON analytics_funnel_results
    USING (
        EXISTS (
            SELECT 1 FROM analytics_funnels f
            WHERE f.id = funnel_id
              AND f.tenant_id = current_setting('app.tenant_id', true)::text
              AND current_setting('app.tenant_id', true) != ''
        )
    );

-- retention has no tenant_id — scoped through parent cohort
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
--          Also fixes notifications policy (same empty-string bug as
--          F-SQL03 — unset tenant_id exposes all notifications).
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_notif_prefs ON notification_preferences
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS super_admin_all ON notification_preferences;
CREATE POLICY super_admin_all ON notification_preferences
    USING (current_setting('app.user_role', true) = 'super_admin');

-- Fix notifications policy — same empty-string vulnerability as billing
DROP POLICY IF EXISTS tenant_isolation_notifications ON notifications;
CREATE POLICY tenant_isolation_notifications ON notifications
    USING (
        tenant_id = current_setting('app.tenant_id', true)::text
        AND current_setting('app.tenant_id', true) != ''
    );

DROP POLICY IF EXISTS super_admin_all ON notifications;
CREATE POLICY super_admin_all ON notifications
    USING (current_setting('app.user_role', true) = 'super_admin');

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- ── Reverse F-SQL40 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS super_admin_all                ON notifications;
DROP POLICY IF EXISTS tenant_isolation_notifications ON notifications;
CREATE POLICY tenant_isolation_notifications ON notifications
    USING (current_setting('app.tenant_id', true) = '' OR tenant_id = current_setting('app.tenant_id', true));
DROP POLICY IF EXISTS super_admin_all          ON notification_preferences;
DROP POLICY IF EXISTS tenant_isolation_notif_prefs ON notification_preferences;
ALTER TABLE notification_preferences DISABLE ROW LEVEL SECURITY;

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

-- ── Reverse F-SQL25 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_flag_evaluations ON flag_evaluations;
DROP POLICY IF EXISTS super_admin_all ON flag_evaluations;
ALTER TABLE flag_evaluations DISABLE ROW LEVEL SECURITY;
DROP INDEX IF EXISTS idx_flag_evaluations_tenant;
CREATE INDEX IF NOT EXISTS idx_flag_evaluations_tenant
    ON flag_evaluations (tenant_id, evaluated_at DESC)
    WHERE tenant_id IS NOT NULL;
ALTER TABLE flag_evaluations ALTER COLUMN tenant_id DROP NOT NULL;
ALTER TABLE flag_evaluations ALTER COLUMN tenant_id DROP DEFAULT;
UPDATE flag_evaluations SET tenant_id = NULL WHERE tenant_id = 'system';

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
ALTER TABLE schema_versions ENABLE ROW LEVEL SECURITY;

-- ── Reverse F-SQL06 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS super_admin_only          ON system_config;
DROP POLICY IF EXISTS super_admin_only          ON kill_switches;
DROP POLICY IF EXISTS super_admin_only          ON maintenance_windows;
DROP POLICY IF EXISTS read_active_announcements ON announcements;
DROP POLICY IF EXISTS super_admin_impersonation ON impersonation_log;
DROP POLICY IF EXISTS self_impersonation_view   ON impersonation_log;
ALTER TABLE system_config         DISABLE ROW LEVEL SECURITY;
ALTER TABLE kill_switches         DISABLE ROW LEVEL SECURITY;
ALTER TABLE maintenance_windows   DISABLE ROW LEVEL SECURITY;
ALTER TABLE announcements         DISABLE ROW LEVEL SECURITY;
ALTER TABLE impersonation_log     DISABLE ROW LEVEL SECURITY;

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
DROP POLICY IF EXISTS super_admin_all ON active_sessions;
DROP POLICY IF EXISTS super_admin_all ON api_keys;
DROP POLICY IF EXISTS super_admin_all ON mfa_secrets;
DROP POLICY IF EXISTS super_admin_all ON password_history;
DROP POLICY IF EXISTS super_admin_all ON account_recovery_tokens;

-- ── Reverse F-SQL01 ──────────────────────────────────────────────────
DROP POLICY IF EXISTS tenant_isolation_users ON users;
CREATE POLICY tenant_isolation_users ON users USING (true);

-- +goose StatementEnd
