-- ============================================================
-- services/auth/internal/postgres/migrations/031_fix_step_0.3.sql
-- Scope: auth service database only — independent migration sequence
--
-- STATUS: SUPERSEDED — intentional no-op
--
-- All six fixes (F-SQL08, F-SQL10, F-SQL16, F-SQL17, F-SQL18, F-SQL23)
-- were fully and correctly implemented in 025_add_missing_columns.sql,
-- which runs before this file in the migration sequence.
--
-- Additionally, 031's RLS USING clause omitted the 'system' tenant
-- passthrough present in 025, which would have broken access to
-- platform-owned ML models from tenant sessions.
--
-- Superseded by: 025_add_missing_columns.sql
-- ============================================================

-- +goose Up
-- +goose StatementBegin
SELECT 'no-op: superseded by 025_add_missing_columns';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
SELECT 'no-op: nothing to reverse';
-- +goose StatementEnd
