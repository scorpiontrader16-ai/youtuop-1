-- ============================================================
-- services/auth/internal/postgres/migrations/009_auth_features.sql
-- Scope: auth service database only — independent migration sequence
-- Global numbering reflects creation order across all services
-- ============================================================
-- +goose Up
-- +goose StatementBegin

-- جدول MFA (TOTP)
CREATE TABLE IF NOT EXISTS mfa_secrets (
    id             BIGSERIAL PRIMARY KEY,
    user_id        TEXT      NOT NULL,
    tenant_id      TEXT      NOT NULL,
    secret         TEXT      NOT NULL,
    enabled        BOOLEAN   NOT NULL DEFAULT FALSE,
    verified       BOOLEAN   NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول محاولات SMS MFA
CREATE TABLE IF NOT EXISTS sms_mfa_attempts (
    id             BIGSERIAL PRIMARY KEY,
    user_id        TEXT      NOT NULL,
    tenant_id      TEXT      NOT NULL,
    phone_number   TEXT      NOT NULL,
    code           TEXT      NOT NULL,
    expires_at     TIMESTAMPTZ NOT NULL,
    verified       BOOLEAN   NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- توسيع جدول sessions (إضافة device_fingerprint)
ALTER TABLE active_sessions ADD COLUMN IF NOT EXISTS device_fingerprint TEXT;

-- جدول محاولات تسجيل الدخول الفاشلة (brute force)
CREATE TABLE IF NOT EXISTS failed_login_attempts (
    id             BIGSERIAL PRIMARY KEY,
    user_id        TEXT,
    ip_address     INET,
    attempted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول تاريخ كلمات المرور (لمنع إعادة الاستخدام)
CREATE TABLE IF NOT EXISTS password_history (
    id             BIGSERIAL PRIMARY KEY,
    user_id        TEXT      NOT NULL,
    tenant_id      TEXT      NOT NULL,
    password_hash  TEXT      NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول روابط استعادة الحساب
CREATE TABLE IF NOT EXISTS account_recovery_tokens (
    id             BIGSERIAL PRIMARY KEY,
    user_id        TEXT      NOT NULL,
    tenant_id      TEXT      NOT NULL,
    token          TEXT      NOT NULL UNIQUE,
    expires_at     TIMESTAMPTZ NOT NULL,
    used_at        TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول مفاتيح API
CREATE TABLE IF NOT EXISTS api_keys (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    user_id        TEXT      NOT NULL,
    name           TEXT      NOT NULL,
    key_hash       TEXT      NOT NULL,
    permissions    TEXT[]    NOT NULL DEFAULT '{}',
    expires_at     TIMESTAMPTZ,
    last_used_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- فهارس
CREATE INDEX IF NOT EXISTS idx_mfa_secrets_user ON mfa_secrets(user_id);
CREATE INDEX IF NOT EXISTS idx_failed_attempts_user ON failed_login_attempts(user_id);
CREATE INDEX IF NOT EXISTS idx_failed_attempts_ip ON failed_login_attempts(ip_address);
CREATE INDEX IF NOT EXISTS idx_password_history_user ON password_history(user_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_recovery_tokens_user ON account_recovery_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_recovery_tokens_token ON account_recovery_tokens(token);
CREATE INDEX IF NOT EXISTS idx_api_keys_user ON api_keys(user_id, tenant_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS api_keys CASCADE;
DROP TABLE IF EXISTS account_recovery_tokens CASCADE;
DROP TABLE IF EXISTS password_history CASCADE;
DROP TABLE IF EXISTS failed_login_attempts CASCADE;
DROP TABLE IF EXISTS sms_mfa_attempts CASCADE;
DROP TABLE IF EXISTS mfa_secrets CASCADE;
ALTER TABLE active_sessions DROP COLUMN IF EXISTS device_fingerprint;
-- +goose StatementEnd
