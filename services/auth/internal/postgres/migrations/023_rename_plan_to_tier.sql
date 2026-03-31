-- ============================================================
-- services/auth/internal/postgres/migrations/023_rename_plan_to_tier.sql
-- Scope: auth service database only — independent migration sequence
-- ============================================================
-- M8/M9: renames tenants.plan → tenants.tier, enforces 3-value constraint.
-- Migration 004 (ingestion) created the column as "plan" with 4 values.
-- This migration standardises the name and drops the unused "business" value.
-- +goose Up
-- +goose StatementBegin

-- 1. migrate any existing "business" rows to "enterprise" before constraint change
UPDATE tenants SET plan = 'enterprise' WHERE plan = 'business';

-- 2. rename column
ALTER TABLE tenants RENAME COLUMN plan TO tier;

-- 3. replace the 4-value constraint with the 3-value M8 spec
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS chk_tenant_plan;
ALTER TABLE tenants ADD CONSTRAINT chk_tenant_tier
    CHECK (tier IN ('basic', 'pro', 'enterprise'));

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS chk_tenant_tier;
ALTER TABLE tenants RENAME COLUMN tier TO plan;
ALTER TABLE tenants ADD CONSTRAINT chk_tenant_plan
    CHECK (plan IN ('basic', 'pro', 'business', 'enterprise'));

-- +goose StatementEnd
