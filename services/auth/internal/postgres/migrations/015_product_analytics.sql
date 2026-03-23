-- +goose Up
-- +goose StatementBegin

-- جدول الأحداث (Event Tracking)
CREATE TABLE IF NOT EXISTS analytics_events (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    user_id        TEXT      NOT NULL,
    session_id     TEXT,
    event_type     TEXT      NOT NULL,
    event_name     TEXT      NOT NULL,
    properties     JSONB     NOT NULL DEFAULT '{}',
    timestamp      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address     INET,
    user_agent     TEXT
);

-- جدول مسارات المستخدم (User Journeys) – مجمع حسب الجلسة
CREATE TABLE IF NOT EXISTS analytics_user_journeys (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    user_id        TEXT      NOT NULL,
    session_id     TEXT      NOT NULL,
    journey_data   JSONB     NOT NULL,  -- قائمة الأحداث
    started_at     TIMESTAMPTZ NOT NULL,
    ended_at       TIMESTAMPTZ,
    duration_sec   INTEGER,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول تعريفات القمع (Funnels)
CREATE TABLE IF NOT EXISTS analytics_funnels (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    name           TEXT      NOT NULL,
    description    TEXT,
    steps          JSONB     NOT NULL,  -- مصفوفة من الخطوات (event_name)
    created_by     TEXT      NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول نتائج القمع (محسوبة مسبقاً لسرعة العرض)
CREATE TABLE IF NOT EXISTS analytics_funnel_results (
    id             BIGSERIAL PRIMARY KEY,
    funnel_id      BIGINT    NOT NULL REFERENCES analytics_funnels(id) ON DELETE CASCADE,
    tenant_id      TEXT      NOT NULL,
    cohort_date    DATE      NOT NULL,  -- تاريخ بداية المجموعة
    step_index     INTEGER   NOT NULL,
    step_name      TEXT      NOT NULL,
    user_count     INTEGER   NOT NULL,
    conversion_rate DECIMAL(5,2),
    computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول تعريف المجموعات (Cohorts) مثلاً حسب تاريخ التسجيل
CREATE TABLE IF NOT EXISTS analytics_cohorts (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    name           TEXT      NOT NULL,
    cohort_type    TEXT      NOT NULL,  -- 'registration_date', 'first_event', etc.
    definition     JSONB     NOT NULL,
    created_by     TEXT      NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- جدول الاحتفاظ (Retention) – محسوب مسبقاً
CREATE TABLE IF NOT EXISTS analytics_retention (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    cohort_id      BIGINT    NOT NULL REFERENCES analytics_cohorts(id) ON DELETE CASCADE,
    cohort_date    DATE      NOT NULL,
    period_number  INTEGER   NOT NULL,  -- day 1, day 7, day 30
    retention_rate DECIMAL(5,2),
    user_count     INTEGER   NOT NULL,
    computed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- فهارس
CREATE INDEX IF NOT EXISTS idx_analytics_events_tenant_time ON analytics_events(tenant_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_analytics_events_user ON analytics_events(tenant_id, user_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_analytics_events_type ON analytics_events(event_type, event_name);
CREATE INDEX IF NOT EXISTS idx_analytics_user_journeys_session ON analytics_user_journeys(tenant_id, session_id);
CREATE INDEX IF NOT EXISTS idx_analytics_funnel_results_funnel_cohort ON analytics_funnel_results(funnel_id, cohort_date);
CREATE INDEX IF NOT EXISTS idx_analytics_retention_cohort_period ON analytics_retention(cohort_id, period_number);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS analytics_retention CASCADE;
DROP TABLE IF EXISTS analytics_funnel_results CASCADE;
DROP TABLE IF EXISTS analytics_funnels CASCADE;
DROP TABLE IF EXISTS analytics_user_journeys CASCADE;
DROP TABLE IF EXISTS analytics_events CASCADE;
DROP TABLE IF EXISTS analytics_cohorts CASCADE;
-- +goose StatementEnd
