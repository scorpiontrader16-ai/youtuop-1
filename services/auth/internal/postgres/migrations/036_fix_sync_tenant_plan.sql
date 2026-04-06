-- ============================================================
-- services/auth/internal/postgres/migrations/036_fix_sync_tenant_plan.sql
-- Scope: auth service database only — independent migration sequence
-- Global numbering reflects creation order across all services
--
-- Fixes:
--   BUG-CRITICAL: sync_tenant_plan() in migrations 026/027/028
--                 references NEW.plan_id which does NOT exist in
--                 the subscriptions table. The actual column is
--                 subscriptions.plan (TEXT: basic/pro/business/enterprise).
--
--                 Every subscription INSERT or UPDATE OF status/plan
--                 fires the trigger which immediately throws:
--                   ERROR: record "new" has no field "plan_id"
--
--                 This means ALL subscription status changes fail,
--                 tenants never receive their correct tier, and
--                 billing sync is completely broken since 026 was applied.
--
--   BUG-SECONDARY: write_audit() is defined in both auth/027 and
--                  control-plane/010 in the same database (POSTGRES_DB=platform).
--                  This migration pins the canonical definition with
--                  public.audit_log prefix to ensure consistent behavior
--                  regardless of which service migration runs last.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- BUG-CRITICAL: Fix sync_tenant_plan() — use NEW.plan not NEW.plan_id
--
-- subscriptions.plan values: 'basic' | 'pro' | 'business' | 'enterprise'
-- tenants.tier  values:      'basic' | 'pro' | 'business' | 'enterprise'
-- Mapping is direct 1:1 — no translation needed.
--
-- Trigger definition (from 006_billing.sql):
--   AFTER INSERT OR UPDATE OF status, plan ON subscriptions
-- So NEW.plan is always available when this function runs.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION sync_tenant_plan()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_tier TEXT;
BEGIN
    IF NEW.status IN ('active', 'trialing') THEN
        v_new_tier := CASE NEW.plan
            WHEN 'basic'      THEN 'basic'
            WHEN 'pro'        THEN 'pro'
            WHEN 'business'   THEN 'business'
            WHEN 'enterprise' THEN 'enterprise'
            ELSE NULL
        END;

        IF v_new_tier IS NULL THEN
            RAISE WARNING
                'sync_tenant_plan: unknown plan=% for tenant=% subscription=% — tier unchanged',
                NEW.plan, NEW.tenant_id, NEW.id;
        ELSE
            UPDATE tenants
               SET tier       = v_new_tier,
                   updated_at = NOW()
             WHERE id = NEW.tenant_id;
        END IF;

    ELSIF NEW.status IN ('cancelled', 'unpaid', 'past_due') THEN
        UPDATE tenants
           SET tier       = 'basic',
               updated_at = NOW()
         WHERE id = NEW.tenant_id;

    END IF;
    RETURN NEW;
END;
$$;

-- ════════════════════════════════════════════════════════════════════
-- BUG-SECONDARY: Pin canonical write_audit() with public. schema prefix.
-- ════════════════════════════════════════════════════════════════════
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
    INSERT INTO public.audit_log (
        tenant_id, user_id, action, resource, resource_id,
        old_data, new_data, ip_address, trace_id, status, error
    ) VALUES (
        p_tenant_id, p_user_id, p_action, p_resource, p_resource_id,
        p_old_data, p_new_data, p_ip_address, p_trace_id, p_status, p_error
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'write_audit failed: %', SQLERRM;
END;
$$;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Reverse: restore 028 broken version for goose symmetry.
-- WARNING: applying this Down restores the broken billing trigger.
CREATE OR REPLACE FUNCTION sync_tenant_plan()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_new_tier TEXT;
BEGIN
    IF NEW.status IN ('active', 'trialing') THEN
        v_new_tier := CASE NEW.plan_id
            WHEN 'plan_basic'      THEN 'basic'
            WHEN 'plan_pro'        THEN 'pro'
            WHEN 'plan_business'   THEN 'pro'
            WHEN 'plan_enterprise' THEN 'enterprise'
            ELSE NULL
        END;

        IF v_new_tier IS NULL THEN
            RAISE WARNING
                'sync_tenant_plan: unknown plan_id=% for tenant=% subscription=% — tier unchanged',
                NEW.plan_id, NEW.tenant_id, NEW.id;
        ELSE
            UPDATE tenants
               SET tier       = v_new_tier,
                   updated_at = NOW()
             WHERE id = NEW.tenant_id;
        END IF;

    ELSIF NEW.status IN ('cancelled', 'unpaid', 'past_due') THEN
        UPDATE tenants
           SET tier       = 'basic',
               updated_at = NOW()
         WHERE id = NEW.tenant_id;
    END IF;
    RETURN NEW;
END;
$$;

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
    RAISE WARNING 'write_audit failed: %', SQLERRM;
END;
$$;

-- +goose StatementEnd
