-- 003_parquet_keys.sql
-- +goose Up
ALTER TABLE warm_events 
ADD COLUMN IF NOT EXISTS parquet_key TEXT DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_warm_events_parquet_key 
ON warm_events(parquet_key) 
WHERE parquet_key IS NOT NULL;

-- +goose Down
ALTER TABLE warm_events DROP COLUMN IF EXISTS parquet_key;
