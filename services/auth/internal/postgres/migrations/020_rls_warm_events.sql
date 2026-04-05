-- ============================================================
-- services/auth/internal/postgres/migrations/020_rls_warm_events.sql
-- Scope: auth service database only — independent migration sequence
--
-- STATUS: ARCHITECTURAL ERROR — intentional no-op
--
-- This migration attempts to enable RLS on:
--   warm_events     → belongs to ingestion service, not auth service
--   tiering_jobs    → belongs to ingestion service, not auth service
--   schema_versions → internal goose tracking table, not tenant data
--
-- Applying this migration on the auth service DB causes:
--   ERROR: relation "warm_events" does not exist (SQLSTATE 42P01)
--
-- RLS for ingestion service tables must be applied via ingestion
-- service migrations, not auth service migrations. Cross-service
-- migration dependencies are an architectural violation.
--
-- schema_versions (goose tracking) must NOT have RLS — blocking
-- goose's own access to it breaks all future migrations. This is
-- correctly fixed in 024_fix_rls_policies.sql (F-SQL12).
--
-- This file is intentionally a no-op to preserve migration sequence
-- integrity without gaps in numbering.
-- ============================================================

-- +goose Up
-- +goose StatementBegin
-- Intentional no-op: tables belong to ingestion service, not auth service.
-- warm_events RLS   → apply in services/ingestion/internal/postgres/migrations/
-- tiering_jobs RLS  → apply in services/ingestion/internal/postgres/migrations/
-- schema_versions   → must NOT have RLS (fixed in 024 via F-SQL12)
SELECT 'no-op: cross-service architectural error — see comment above';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
SELECT 'no-op: nothing to reverse';
-- +goose StatementEnd
