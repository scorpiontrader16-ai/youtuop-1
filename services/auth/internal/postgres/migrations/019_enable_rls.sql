-- ============================================================
-- services/auth/internal/postgres/migrations/019_enable_rls.sql
-- Scope: auth service database only — independent migration sequence
-- ============================================================
-- +goose Up
-- +goose StatementBegin

-- تفعيل RLS على جميع الجداول
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE mfa_secrets ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE account_recovery_tokens ENABLE ROW LEVEL SECURITY;

-- حذف policies الموجودة مسبقاً (من 005) قبل إعادة الإنشاء
DROP POLICY IF EXISTS tenant_isolation_tenants ON tenants;
DROP POLICY IF EXISTS tenant_isolation_users ON users;
DROP POLICY IF EXISTS tenant_isolation_user_roles ON user_roles;
DROP POLICY IF EXISTS tenant_isolation_sessions ON sessions;
DROP POLICY IF EXISTS tenant_isolation_mfa ON mfa_secrets;
DROP POLICY IF EXISTS tenant_isolation_api_keys ON api_keys;
DROP POLICY IF EXISTS tenant_isolation_password_history ON password_history;
DROP POLICY IF EXISTS tenant_isolation_recovery_tokens ON account_recovery_tokens;
DROP POLICY IF EXISTS super_admin_all ON tenants;

-- إنشاء policies
CREATE POLICY tenant_isolation_tenants ON tenants USING (id = current_setting('app.tenant_id', true)::text);
CREATE POLICY tenant_isolation_users ON users USING (true); -- المستخدمون عالميون لكن الصلاحيات تحد
CREATE POLICY tenant_isolation_user_roles ON user_roles USING (tenant_id = current_setting('app.tenant_id', true)::text);
CREATE POLICY tenant_isolation_sessions ON sessions USING (tenant_id = current_setting('app.tenant_id', true)::text);
CREATE POLICY tenant_isolation_mfa ON mfa_secrets USING (tenant_id = current_setting('app.tenant_id', true)::text);
CREATE POLICY tenant_isolation_api_keys ON api_keys USING (tenant_id = current_setting('app.tenant_id', true)::text);
CREATE POLICY tenant_isolation_password_history ON password_history USING (tenant_id = current_setting('app.tenant_id', true)::text);
CREATE POLICY tenant_isolation_recovery_tokens ON account_recovery_tokens USING (tenant_id = current_setting('app.tenant_id', true)::text);

CREATE POLICY super_admin_all ON tenants USING (current_setting('app.user_role', true) = 'super_admin');

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP POLICY IF EXISTS tenant_isolation_tenants ON tenants;
DROP POLICY IF EXISTS tenant_isolation_users ON users;
DROP POLICY IF EXISTS tenant_isolation_user_roles ON user_roles;
DROP POLICY IF EXISTS tenant_isolation_sessions ON sessions;
DROP POLICY IF EXISTS tenant_isolation_mfa ON mfa_secrets;
DROP POLICY IF EXISTS tenant_isolation_api_keys ON api_keys;
DROP POLICY IF EXISTS tenant_isolation_password_history ON password_history;
DROP POLICY IF EXISTS tenant_isolation_recovery_tokens ON account_recovery_tokens;
DROP POLICY IF EXISTS super_admin_all ON tenants;
-- +goose StatementEnd
