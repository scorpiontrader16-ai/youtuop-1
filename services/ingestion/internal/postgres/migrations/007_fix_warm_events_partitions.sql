-- ============================================================
-- services/ingestion/internal/postgres/migrations/007_fix_warm_events_partitions.sql
-- Scope: ingestion service database only — independent migration sequence
-- Global numbering reflects creation order across all services
--
-- Fixes:
--   F-SQL32 PARTIAL: 006_partition_warm_events.sql created warm_events
--                    as a partitioned table but only added w01 and w52
--                    for 2026 and 2027. Weeks w02→w51 were missing,
--                    causing all data in those ranges to fall into
--                    warm_events_default — defeating the purpose of
--                    partitioning (efficient DROP-based retention cleanup).
--
--   This migration adds the 50 missing weekly partitions for each of
--   2026 and 2027 (total: 100 partitions).
--
--   Existing data in warm_events_default is NOT automatically moved —
--   PostgreSQL does not relocate rows when new partitions are added.
--   New writes from these date ranges will route correctly after this
--   migration. Historical data in default partition is acceptable for
--   a hot event cache with 30-day retention policy.
-- ============================================================

-- +goose Up
-- +goose StatementBegin

-- ════════════════════════════════════════════════════════════════════
-- 2026 missing partitions: w02 → w51
-- w01: 2026-01-01 → 2026-01-08 (exists in 006)
-- w52: 2026-12-24 → 2026-12-31 (exists in 006)
-- ════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS warm_events_2026_w02 PARTITION OF warm_events
    FOR VALUES FROM ('2026-01-08') TO ('2026-01-15');
CREATE TABLE IF NOT EXISTS warm_events_2026_w03 PARTITION OF warm_events
    FOR VALUES FROM ('2026-01-15') TO ('2026-01-22');
CREATE TABLE IF NOT EXISTS warm_events_2026_w04 PARTITION OF warm_events
    FOR VALUES FROM ('2026-01-22') TO ('2026-01-29');
CREATE TABLE IF NOT EXISTS warm_events_2026_w05 PARTITION OF warm_events
    FOR VALUES FROM ('2026-01-29') TO ('2026-02-05');
CREATE TABLE IF NOT EXISTS warm_events_2026_w06 PARTITION OF warm_events
    FOR VALUES FROM ('2026-02-05') TO ('2026-02-12');
CREATE TABLE IF NOT EXISTS warm_events_2026_w07 PARTITION OF warm_events
    FOR VALUES FROM ('2026-02-12') TO ('2026-02-19');
CREATE TABLE IF NOT EXISTS warm_events_2026_w08 PARTITION OF warm_events
    FOR VALUES FROM ('2026-02-19') TO ('2026-02-26');
CREATE TABLE IF NOT EXISTS warm_events_2026_w09 PARTITION OF warm_events
    FOR VALUES FROM ('2026-02-26') TO ('2026-03-05');
CREATE TABLE IF NOT EXISTS warm_events_2026_w10 PARTITION OF warm_events
    FOR VALUES FROM ('2026-03-05') TO ('2026-03-12');
CREATE TABLE IF NOT EXISTS warm_events_2026_w11 PARTITION OF warm_events
    FOR VALUES FROM ('2026-03-12') TO ('2026-03-19');
CREATE TABLE IF NOT EXISTS warm_events_2026_w12 PARTITION OF warm_events
    FOR VALUES FROM ('2026-03-19') TO ('2026-03-26');
CREATE TABLE IF NOT EXISTS warm_events_2026_w13 PARTITION OF warm_events
    FOR VALUES FROM ('2026-03-26') TO ('2026-04-02');
CREATE TABLE IF NOT EXISTS warm_events_2026_w14 PARTITION OF warm_events
    FOR VALUES FROM ('2026-04-02') TO ('2026-04-09');
CREATE TABLE IF NOT EXISTS warm_events_2026_w15 PARTITION OF warm_events
    FOR VALUES FROM ('2026-04-09') TO ('2026-04-16');
CREATE TABLE IF NOT EXISTS warm_events_2026_w16 PARTITION OF warm_events
    FOR VALUES FROM ('2026-04-16') TO ('2026-04-23');
CREATE TABLE IF NOT EXISTS warm_events_2026_w17 PARTITION OF warm_events
    FOR VALUES FROM ('2026-04-23') TO ('2026-04-30');
CREATE TABLE IF NOT EXISTS warm_events_2026_w18 PARTITION OF warm_events
    FOR VALUES FROM ('2026-04-30') TO ('2026-05-07');
CREATE TABLE IF NOT EXISTS warm_events_2026_w19 PARTITION OF warm_events
    FOR VALUES FROM ('2026-05-07') TO ('2026-05-14');
CREATE TABLE IF NOT EXISTS warm_events_2026_w20 PARTITION OF warm_events
    FOR VALUES FROM ('2026-05-14') TO ('2026-05-21');
CREATE TABLE IF NOT EXISTS warm_events_2026_w21 PARTITION OF warm_events
    FOR VALUES FROM ('2026-05-21') TO ('2026-05-28');
CREATE TABLE IF NOT EXISTS warm_events_2026_w22 PARTITION OF warm_events
    FOR VALUES FROM ('2026-05-28') TO ('2026-06-04');
CREATE TABLE IF NOT EXISTS warm_events_2026_w23 PARTITION OF warm_events
    FOR VALUES FROM ('2026-06-04') TO ('2026-06-11');
CREATE TABLE IF NOT EXISTS warm_events_2026_w24 PARTITION OF warm_events
    FOR VALUES FROM ('2026-06-11') TO ('2026-06-18');
CREATE TABLE IF NOT EXISTS warm_events_2026_w25 PARTITION OF warm_events
    FOR VALUES FROM ('2026-06-18') TO ('2026-06-25');
CREATE TABLE IF NOT EXISTS warm_events_2026_w26 PARTITION OF warm_events
    FOR VALUES FROM ('2026-06-25') TO ('2026-07-02');
CREATE TABLE IF NOT EXISTS warm_events_2026_w27 PARTITION OF warm_events
    FOR VALUES FROM ('2026-07-02') TO ('2026-07-09');
CREATE TABLE IF NOT EXISTS warm_events_2026_w28 PARTITION OF warm_events
    FOR VALUES FROM ('2026-07-09') TO ('2026-07-16');
CREATE TABLE IF NOT EXISTS warm_events_2026_w29 PARTITION OF warm_events
    FOR VALUES FROM ('2026-07-16') TO ('2026-07-23');
CREATE TABLE IF NOT EXISTS warm_events_2026_w30 PARTITION OF warm_events
    FOR VALUES FROM ('2026-07-23') TO ('2026-07-30');
CREATE TABLE IF NOT EXISTS warm_events_2026_w31 PARTITION OF warm_events
    FOR VALUES FROM ('2026-07-30') TO ('2026-08-06');
CREATE TABLE IF NOT EXISTS warm_events_2026_w32 PARTITION OF warm_events
    FOR VALUES FROM ('2026-08-06') TO ('2026-08-13');
CREATE TABLE IF NOT EXISTS warm_events_2026_w33 PARTITION OF warm_events
    FOR VALUES FROM ('2026-08-13') TO ('2026-08-20');
CREATE TABLE IF NOT EXISTS warm_events_2026_w34 PARTITION OF warm_events
    FOR VALUES FROM ('2026-08-20') TO ('2026-08-27');
CREATE TABLE IF NOT EXISTS warm_events_2026_w35 PARTITION OF warm_events
    FOR VALUES FROM ('2026-08-27') TO ('2026-09-03');
CREATE TABLE IF NOT EXISTS warm_events_2026_w36 PARTITION OF warm_events
    FOR VALUES FROM ('2026-09-03') TO ('2026-09-10');
CREATE TABLE IF NOT EXISTS warm_events_2026_w37 PARTITION OF warm_events
    FOR VALUES FROM ('2026-09-10') TO ('2026-09-17');
CREATE TABLE IF NOT EXISTS warm_events_2026_w38 PARTITION OF warm_events
    FOR VALUES FROM ('2026-09-17') TO ('2026-09-24');
CREATE TABLE IF NOT EXISTS warm_events_2026_w39 PARTITION OF warm_events
    FOR VALUES FROM ('2026-09-24') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS warm_events_2026_w40 PARTITION OF warm_events
    FOR VALUES FROM ('2026-10-01') TO ('2026-10-08');
CREATE TABLE IF NOT EXISTS warm_events_2026_w41 PARTITION OF warm_events
    FOR VALUES FROM ('2026-10-08') TO ('2026-10-15');
CREATE TABLE IF NOT EXISTS warm_events_2026_w42 PARTITION OF warm_events
    FOR VALUES FROM ('2026-10-15') TO ('2026-10-22');
CREATE TABLE IF NOT EXISTS warm_events_2026_w43 PARTITION OF warm_events
    FOR VALUES FROM ('2026-10-22') TO ('2026-10-29');
CREATE TABLE IF NOT EXISTS warm_events_2026_w44 PARTITION OF warm_events
    FOR VALUES FROM ('2026-10-29') TO ('2026-11-05');
CREATE TABLE IF NOT EXISTS warm_events_2026_w45 PARTITION OF warm_events
    FOR VALUES FROM ('2026-11-05') TO ('2026-11-12');
CREATE TABLE IF NOT EXISTS warm_events_2026_w46 PARTITION OF warm_events
    FOR VALUES FROM ('2026-11-12') TO ('2026-11-19');
CREATE TABLE IF NOT EXISTS warm_events_2026_w47 PARTITION OF warm_events
    FOR VALUES FROM ('2026-11-19') TO ('2026-11-26');
CREATE TABLE IF NOT EXISTS warm_events_2026_w48 PARTITION OF warm_events
    FOR VALUES FROM ('2026-11-26') TO ('2026-12-03');
CREATE TABLE IF NOT EXISTS warm_events_2026_w49 PARTITION OF warm_events
    FOR VALUES FROM ('2026-12-03') TO ('2026-12-10');
CREATE TABLE IF NOT EXISTS warm_events_2026_w50 PARTITION OF warm_events
    FOR VALUES FROM ('2026-12-10') TO ('2026-12-17');
CREATE TABLE IF NOT EXISTS warm_events_2026_w51 PARTITION OF warm_events
    FOR VALUES FROM ('2026-12-17') TO ('2026-12-24');

-- ════════════════════════════════════════════════════════════════════
-- 2027 missing partitions: w02 → w51
-- w01: 2027-01-01 → 2027-01-08 (exists in 006)
-- w52: 2027-12-24 → 2027-12-31 (exists in 006)
-- ════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS warm_events_2027_w02 PARTITION OF warm_events
    FOR VALUES FROM ('2027-01-08') TO ('2027-01-15');
CREATE TABLE IF NOT EXISTS warm_events_2027_w03 PARTITION OF warm_events
    FOR VALUES FROM ('2027-01-15') TO ('2027-01-22');
CREATE TABLE IF NOT EXISTS warm_events_2027_w04 PARTITION OF warm_events
    FOR VALUES FROM ('2027-01-22') TO ('2027-01-29');
CREATE TABLE IF NOT EXISTS warm_events_2027_w05 PARTITION OF warm_events
    FOR VALUES FROM ('2027-01-29') TO ('2027-02-05');
CREATE TABLE IF NOT EXISTS warm_events_2027_w06 PARTITION OF warm_events
    FOR VALUES FROM ('2027-02-05') TO ('2027-02-12');
CREATE TABLE IF NOT EXISTS warm_events_2027_w07 PARTITION OF warm_events
    FOR VALUES FROM ('2027-02-12') TO ('2027-02-19');
CREATE TABLE IF NOT EXISTS warm_events_2027_w08 PARTITION OF warm_events
    FOR VALUES FROM ('2027-02-19') TO ('2027-02-26');
CREATE TABLE IF NOT EXISTS warm_events_2027_w09 PARTITION OF warm_events
    FOR VALUES FROM ('2027-02-26') TO ('2027-03-05');
CREATE TABLE IF NOT EXISTS warm_events_2027_w10 PARTITION OF warm_events
    FOR VALUES FROM ('2027-03-05') TO ('2027-03-12');
CREATE TABLE IF NOT EXISTS warm_events_2027_w11 PARTITION OF warm_events
    FOR VALUES FROM ('2027-03-12') TO ('2027-03-19');
CREATE TABLE IF NOT EXISTS warm_events_2027_w12 PARTITION OF warm_events
    FOR VALUES FROM ('2027-03-19') TO ('2027-03-26');
CREATE TABLE IF NOT EXISTS warm_events_2027_w13 PARTITION OF warm_events
    FOR VALUES FROM ('2027-03-26') TO ('2027-04-02');
CREATE TABLE IF NOT EXISTS warm_events_2027_w14 PARTITION OF warm_events
    FOR VALUES FROM ('2027-04-02') TO ('2027-04-09');
CREATE TABLE IF NOT EXISTS warm_events_2027_w15 PARTITION OF warm_events
    FOR VALUES FROM ('2027-04-09') TO ('2027-04-16');
CREATE TABLE IF NOT EXISTS warm_events_2027_w16 PARTITION OF warm_events
    FOR VALUES FROM ('2027-04-16') TO ('2027-04-23');
CREATE TABLE IF NOT EXISTS warm_events_2027_w17 PARTITION OF warm_events
    FOR VALUES FROM ('2027-04-23') TO ('2027-04-30');
CREATE TABLE IF NOT EXISTS warm_events_2027_w18 PARTITION OF warm_events
    FOR VALUES FROM ('2027-04-30') TO ('2027-05-07');
CREATE TABLE IF NOT EXISTS warm_events_2027_w19 PARTITION OF warm_events
    FOR VALUES FROM ('2027-05-07') TO ('2027-05-14');
CREATE TABLE IF NOT EXISTS warm_events_2027_w20 PARTITION OF warm_events
    FOR VALUES FROM ('2027-05-14') TO ('2027-05-21');
CREATE TABLE IF NOT EXISTS warm_events_2027_w21 PARTITION OF warm_events
    FOR VALUES FROM ('2027-05-21') TO ('2027-05-28');
CREATE TABLE IF NOT EXISTS warm_events_2027_w22 PARTITION OF warm_events
    FOR VALUES FROM ('2027-05-28') TO ('2027-06-04');
CREATE TABLE IF NOT EXISTS warm_events_2027_w23 PARTITION OF warm_events
    FOR VALUES FROM ('2027-06-04') TO ('2027-06-11');
CREATE TABLE IF NOT EXISTS warm_events_2027_w24 PARTITION OF warm_events
    FOR VALUES FROM ('2027-06-11') TO ('2027-06-18');
CREATE TABLE IF NOT EXISTS warm_events_2027_w25 PARTITION OF warm_events
    FOR VALUES FROM ('2027-06-18') TO ('2027-06-25');
CREATE TABLE IF NOT EXISTS warm_events_2027_w26 PARTITION OF warm_events
    FOR VALUES FROM ('2027-06-25') TO ('2027-07-02');
CREATE TABLE IF NOT EXISTS warm_events_2027_w27 PARTITION OF warm_events
    FOR VALUES FROM ('2027-07-02') TO ('2027-07-09');
CREATE TABLE IF NOT EXISTS warm_events_2027_w28 PARTITION OF warm_events
    FOR VALUES FROM ('2027-07-09') TO ('2027-07-16');
CREATE TABLE IF NOT EXISTS warm_events_2027_w29 PARTITION OF warm_events
    FOR VALUES FROM ('2027-07-16') TO ('2027-07-23');
CREATE TABLE IF NOT EXISTS warm_events_2027_w30 PARTITION OF warm_events
    FOR VALUES FROM ('2027-07-23') TO ('2027-07-30');
CREATE TABLE IF NOT EXISTS warm_events_2027_w31 PARTITION OF warm_events
    FOR VALUES FROM ('2027-07-30') TO ('2027-08-06');
CREATE TABLE IF NOT EXISTS warm_events_2027_w32 PARTITION OF warm_events
    FOR VALUES FROM ('2027-08-06') TO ('2027-08-13');
CREATE TABLE IF NOT EXISTS warm_events_2027_w33 PARTITION OF warm_events
    FOR VALUES FROM ('2027-08-13') TO ('2027-08-20');
CREATE TABLE IF NOT EXISTS warm_events_2027_w34 PARTITION OF warm_events
    FOR VALUES FROM ('2027-08-20') TO ('2027-08-27');
CREATE TABLE IF NOT EXISTS warm_events_2027_w35 PARTITION OF warm_events
    FOR VALUES FROM ('2027-08-27') TO ('2027-09-03');
CREATE TABLE IF NOT EXISTS warm_events_2027_w36 PARTITION OF warm_events
    FOR VALUES FROM ('2027-09-03') TO ('2027-09-10');
CREATE TABLE IF NOT EXISTS warm_events_2027_w37 PARTITION OF warm_events
    FOR VALUES FROM ('2027-09-10') TO ('2027-09-17');
CREATE TABLE IF NOT EXISTS warm_events_2027_w38 PARTITION OF warm_events
    FOR VALUES FROM ('2027-09-17') TO ('2027-09-24');
CREATE TABLE IF NOT EXISTS warm_events_2027_w39 PARTITION OF warm_events
    FOR VALUES FROM ('2027-09-24') TO ('2027-10-01');
CREATE TABLE IF NOT EXISTS warm_events_2027_w40 PARTITION OF warm_events
    FOR VALUES FROM ('2027-10-01') TO ('2027-10-08');
CREATE TABLE IF NOT EXISTS warm_events_2027_w41 PARTITION OF warm_events
    FOR VALUES FROM ('2027-10-08') TO ('2027-10-15');
CREATE TABLE IF NOT EXISTS warm_events_2027_w42 PARTITION OF warm_events
    FOR VALUES FROM ('2027-10-15') TO ('2027-10-22');
CREATE TABLE IF NOT EXISTS warm_events_2027_w43 PARTITION OF warm_events
    FOR VALUES FROM ('2027-10-22') TO ('2027-10-29');
CREATE TABLE IF NOT EXISTS warm_events_2027_w44 PARTITION OF warm_events
    FOR VALUES FROM ('2027-10-29') TO ('2027-11-05');
CREATE TABLE IF NOT EXISTS warm_events_2027_w45 PARTITION OF warm_events
    FOR VALUES FROM ('2027-11-05') TO ('2027-11-12');
CREATE TABLE IF NOT EXISTS warm_events_2027_w46 PARTITION OF warm_events
    FOR VALUES FROM ('2027-11-12') TO ('2027-11-19');
CREATE TABLE IF NOT EXISTS warm_events_2027_w47 PARTITION OF warm_events
    FOR VALUES FROM ('2027-11-19') TO ('2027-11-26');
CREATE TABLE IF NOT EXISTS warm_events_2027_w48 PARTITION OF warm_events
    FOR VALUES FROM ('2027-11-26') TO ('2027-12-03');
CREATE TABLE IF NOT EXISTS warm_events_2027_w49 PARTITION OF warm_events
    FOR VALUES FROM ('2027-12-03') TO ('2027-12-10');
CREATE TABLE IF NOT EXISTS warm_events_2027_w50 PARTITION OF warm_events
    FOR VALUES FROM ('2027-12-10') TO ('2027-12-17');
CREATE TABLE IF NOT EXISTS warm_events_2027_w51 PARTITION OF warm_events
    FOR VALUES FROM ('2027-12-17') TO ('2027-12-24');

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- ── Reverse 2027 partitions w02→w51 ─────────────────────────────────
DROP TABLE IF EXISTS warm_events_2027_w51;
DROP TABLE IF EXISTS warm_events_2027_w50;
DROP TABLE IF EXISTS warm_events_2027_w49;
DROP TABLE IF EXISTS warm_events_2027_w48;
DROP TABLE IF EXISTS warm_events_2027_w47;
DROP TABLE IF EXISTS warm_events_2027_w46;
DROP TABLE IF EXISTS warm_events_2027_w45;
DROP TABLE IF EXISTS warm_events_2027_w44;
DROP TABLE IF EXISTS warm_events_2027_w43;
DROP TABLE IF EXISTS warm_events_2027_w42;
DROP TABLE IF EXISTS warm_events_2027_w41;
DROP TABLE IF EXISTS warm_events_2027_w40;
DROP TABLE IF EXISTS warm_events_2027_w39;
DROP TABLE IF EXISTS warm_events_2027_w38;
DROP TABLE IF EXISTS warm_events_2027_w37;
DROP TABLE IF EXISTS warm_events_2027_w36;
DROP TABLE IF EXISTS warm_events_2027_w35;
DROP TABLE IF EXISTS warm_events_2027_w34;
DROP TABLE IF EXISTS warm_events_2027_w33;
DROP TABLE IF EXISTS warm_events_2027_w32;
DROP TABLE IF EXISTS warm_events_2027_w31;
DROP TABLE IF EXISTS warm_events_2027_w30;
DROP TABLE IF EXISTS warm_events_2027_w29;
DROP TABLE IF EXISTS warm_events_2027_w28;
DROP TABLE IF EXISTS warm_events_2027_w27;
DROP TABLE IF EXISTS warm_events_2027_w26;
DROP TABLE IF EXISTS warm_events_2027_w25;
DROP TABLE IF EXISTS warm_events_2027_w24;
DROP TABLE IF EXISTS warm_events_2027_w23;
DROP TABLE IF EXISTS warm_events_2027_w22;
DROP TABLE IF EXISTS warm_events_2027_w21;
DROP TABLE IF EXISTS warm_events_2027_w20;
DROP TABLE IF EXISTS warm_events_2027_w19;
DROP TABLE IF EXISTS warm_events_2027_w18;
DROP TABLE IF EXISTS warm_events_2027_w17;
DROP TABLE IF EXISTS warm_events_2027_w16;
DROP TABLE IF EXISTS warm_events_2027_w15;
DROP TABLE IF EXISTS warm_events_2027_w14;
DROP TABLE IF EXISTS warm_events_2027_w13;
DROP TABLE IF EXISTS warm_events_2027_w12;
DROP TABLE IF EXISTS warm_events_2027_w11;
DROP TABLE IF EXISTS warm_events_2027_w10;
DROP TABLE IF EXISTS warm_events_2027_w09;
DROP TABLE IF EXISTS warm_events_2027_w08;
DROP TABLE IF EXISTS warm_events_2027_w07;
DROP TABLE IF EXISTS warm_events_2027_w06;
DROP TABLE IF EXISTS warm_events_2027_w05;
DROP TABLE IF EXISTS warm_events_2027_w04;
DROP TABLE IF EXISTS warm_events_2027_w03;
DROP TABLE IF EXISTS warm_events_2027_w02;

-- ── Reverse 2026 partitions w02→w51 ─────────────────────────────────
DROP TABLE IF EXISTS warm_events_2026_w51;
DROP TABLE IF EXISTS warm_events_2026_w50;
DROP TABLE IF EXISTS warm_events_2026_w49;
DROP TABLE IF EXISTS warm_events_2026_w48;
DROP TABLE IF EXISTS warm_events_2026_w47;
DROP TABLE IF EXISTS warm_events_2026_w46;
DROP TABLE IF EXISTS warm_events_2026_w45;
DROP TABLE IF EXISTS warm_events_2026_w44;
DROP TABLE IF EXISTS warm_events_2026_w43;
DROP TABLE IF EXISTS warm_events_2026_w42;
DROP TABLE IF EXISTS warm_events_2026_w41;
DROP TABLE IF EXISTS warm_events_2026_w40;
DROP TABLE IF EXISTS warm_events_2026_w39;
DROP TABLE IF EXISTS warm_events_2026_w38;
DROP TABLE IF EXISTS warm_events_2026_w37;
DROP TABLE IF EXISTS warm_events_2026_w36;
DROP TABLE IF EXISTS warm_events_2026_w35;
DROP TABLE IF EXISTS warm_events_2026_w34;
DROP TABLE IF EXISTS warm_events_2026_w33;
DROP TABLE IF EXISTS warm_events_2026_w32;
DROP TABLE IF EXISTS warm_events_2026_w31;
DROP TABLE IF EXISTS warm_events_2026_w30;
DROP TABLE IF EXISTS warm_events_2026_w29;
DROP TABLE IF EXISTS warm_events_2026_w28;
DROP TABLE IF EXISTS warm_events_2026_w27;
DROP TABLE IF EXISTS warm_events_2026_w26;
DROP TABLE IF EXISTS warm_events_2026_w25;
DROP TABLE IF EXISTS warm_events_2026_w24;
DROP TABLE IF EXISTS warm_events_2026_w23;
DROP TABLE IF EXISTS warm_events_2026_w22;
DROP TABLE IF EXISTS warm_events_2026_w21;
DROP TABLE IF EXISTS warm_events_2026_w20;
DROP TABLE IF EXISTS warm_events_2026_w19;
DROP TABLE IF EXISTS warm_events_2026_w18;
DROP TABLE IF EXISTS warm_events_2026_w17;
DROP TABLE IF EXISTS warm_events_2026_w16;
DROP TABLE IF EXISTS warm_events_2026_w15;
DROP TABLE IF EXISTS warm_events_2026_w14;
DROP TABLE IF EXISTS warm_events_2026_w13;
DROP TABLE IF EXISTS warm_events_2026_w12;
DROP TABLE IF EXISTS warm_events_2026_w11;
DROP TABLE IF EXISTS warm_events_2026_w10;
DROP TABLE IF EXISTS warm_events_2026_w09;
DROP TABLE IF EXISTS warm_events_2026_w08;
DROP TABLE IF EXISTS warm_events_2026_w07;
DROP TABLE IF EXISTS warm_events_2026_w06;
DROP TABLE IF EXISTS warm_events_2026_w05;
DROP TABLE IF EXISTS warm_events_2026_w04;
DROP TABLE IF EXISTS warm_events_2026_w03;
DROP TABLE IF EXISTS warm_events_2026_w02;

-- +goose StatementEnd
