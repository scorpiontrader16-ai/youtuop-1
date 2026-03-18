-- infra/clickhouse/init.sql
-- Hot Data Schema — يتنفذ تلقائياً عند أول startup

-- ── Database ──────────────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS events;

-- ── Main Events Table ─────────────────────────────────────────────────────
-- MergeTree: الأسرع للـ append-heavy workloads
-- Partition by month: يسرّع الـ time-range queries
-- TTL: بعد 7 أيام ينقل البيانات لـ Postgres (Warm)
CREATE TABLE IF NOT EXISTS events.base_events
(
    -- Identity
    event_id       String,
    event_type     LowCardinality(String),  -- LowCardinality: أسرع لـ repeated values
    source         LowCardinality(String),
    schema_version LowCardinality(String),

    -- Timing
    occurred_at    DateTime64(3, 'UTC'),     -- millisecond precision
    ingested_at    DateTime64(3, 'UTC'),

    -- Routing
    tenant_id      LowCardinality(String),
    partition_key  String,

    -- Payload
    content_type   LowCardinality(String),
    payload        String,                   -- JSON string من الـ metadata
    payload_bytes  UInt32 DEFAULT 0,         -- حجم الـ payload بالـ bytes

    -- Observability
    trace_id       String,
    span_id        String,

    -- Metadata (flattened للـ fast querying)
    meta_keys      Array(String),
    meta_values    Array(String),

    -- Ingestion metadata
    inserted_at    DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (tenant_id, event_type, occurred_at, event_id)
TTL occurred_at + INTERVAL 7 DAY
SETTINGS
    index_granularity = 8192,
    ttl_only_drop_parts = 1;

-- ── Materialized View: Events by Type ─────────────────────────────────────
-- يسرّع الـ queries اللي بتفلتر على event_type
CREATE TABLE IF NOT EXISTS events.events_by_type
(
    event_type  LowCardinality(String),
    tenant_id   LowCardinality(String),
    occurred_at DateTime64(3, 'UTC'),
    event_id    String,
    source      LowCardinality(String),
    trace_id    String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (event_type, tenant_id, occurred_at)
TTL occurred_at + INTERVAL 7 DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS events.mv_events_by_type
TO events.events_by_type
AS SELECT
    event_type,
    tenant_id,
    occurred_at,
    event_id,
    source,
    trace_id
FROM events.base_events;

-- ── Materialized View: Hourly Stats ───────────────────────────────────────
-- لـ Grafana dashboards — aggregated per hour
-- SummingMergeTree يجمع القيم — نخزن total وcount ونحسب avg في الـ query
CREATE TABLE IF NOT EXISTS events.hourly_stats
(
    hour                DateTime,
    tenant_id           LowCardinality(String),
    event_type          LowCardinality(String),
    source              LowCardinality(String),
    event_count         UInt64,
    total_payload_bytes UInt64
)
ENGINE = SummingMergeTree((event_count, total_payload_bytes))
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, tenant_id, event_type, source)
TTL hour + INTERVAL 30 DAY;

-- avg_payload_bytes = total_payload_bytes / event_count في الـ query
CREATE MATERIALIZED VIEW IF NOT EXISTS events.mv_hourly_stats
TO events.hourly_stats
AS SELECT
    toStartOfHour(occurred_at) AS hour,
    tenant_id,
    event_type,
    source,
    count()              AS event_count,
    sum(payload_bytes)   AS total_payload_bytes
FROM events.base_events
GROUP BY hour, tenant_id, event_type, source;

-- ── Platform User (least privilege) ───────────────────────────────────────
CREATE USER IF NOT EXISTS platform IDENTIFIED BY 'platform';
GRANT INSERT, SELECT ON events.* TO platform;
