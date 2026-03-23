-- +goose Up
-- +goose StatementBegin

-- إضافة عمود refresh_token_hash إلى جدول active_sessions
ALTER TABLE active_sessions ADD COLUMN IF NOT EXISTS refresh_token_hash TEXT;

-- إضافة عمود refresh_expires_at إلى جدول active_sessions
ALTER TABLE active_sessions ADD COLUMN IF NOT EXISTS refresh_expires_at TIMESTAMPTZ;

-- إضافة عمود password_hash إلى جدول users (لتسجيل الدخول بالبريد الإلكتروني)
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT;

-- التأكد من وجود عمود slug في جدول tenants
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS slug TEXT;

-- إضافة عمود plan في جدول tenants (إذا لم يكن موجوداً)
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS plan TEXT;

-- التأكد من وجود جدول user_roles
CREATE TABLE IF NOT EXISTS user_roles (
    user_id      TEXT NOT NULL,
    tenant_id    TEXT NOT NULL,
    role         TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, tenant_id)
);

-- إضافة فهارس ضرورية
CREATE INDEX IF NOT EXISTS idx_active_sessions_refresh_token ON active_sessions(refresh_token_hash) WHERE refresh_token_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_tenants_slug ON tenants(slug);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE active_sessions DROP COLUMN IF EXISTS refresh_token_hash;
ALTER TABLE active_sessions DROP COLUMN IF EXISTS refresh_expires_at;
ALTER TABLE users DROP COLUMN IF EXISTS password_hash;
ALTER TABLE tenants DROP COLUMN IF EXISTS slug;
ALTER TABLE tenants DROP COLUMN IF EXISTS plan;
DROP TABLE IF EXISTS user_roles;
-- +goose StatementEnd
