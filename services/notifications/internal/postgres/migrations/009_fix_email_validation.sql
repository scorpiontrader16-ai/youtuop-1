-- ============================================================
-- services/notifications/internal/postgres/migrations/009_fix_email_validation.sql
-- Scope: notifications service database only — independent migration sequence
--
-- Fixes:
--   F-SQL41 (retry): email_log.to_email TEXT without format validation
--                    008_add_email_validation.sql was applied but the
--                    constraint is missing from the actual DB.
--                    This migration adds it idempotently.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- F-SQL41: email_log.to_email TEXT without format validation.
--          Verified missing from pg_constraint on 2026-04-05.
--          Add constraint idempotently (safe to retry).
-- ════════════════════════════════════════════════════════════════════

DO $$ 
BEGIN
    -- Check if constraint already exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conrelid = 'email_log'::regclass 
          AND conname = 'chk_email_format'
    ) THEN
        ALTER TABLE email_log
            ADD CONSTRAINT chk_email_format
            CHECK (to_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
        
        RAISE NOTICE 'chk_email_format constraint added to email_log';
    ELSE
        RAISE NOTICE 'chk_email_format constraint already exists — skipped';
    END IF;
END $$;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

ALTER TABLE email_log
    DROP CONSTRAINT IF EXISTS chk_email_format;

-- +goose StatementEnd
