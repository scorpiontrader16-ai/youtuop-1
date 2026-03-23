-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS search_indices (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    index_name     TEXT      NOT NULL,
    index_type     TEXT      NOT NULL,
    is_active      BOOLEAN   NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, index_type)
);

CREATE TABLE IF NOT EXISTS search_queries (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    user_id        TEXT      NOT NULL,
    query_text     TEXT      NOT NULL,
    filters        JSONB     NOT NULL DEFAULT '{}',
    took_ms        INTEGER   NOT NULL,
    result_count   INTEGER   NOT NULL,
    scored         BOOLEAN   NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS search_clicks (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      TEXT      NOT NULL,
    user_id        TEXT      NOT NULL,
    query_id       BIGINT    NOT NULL REFERENCES search_queries(id) ON DELETE CASCADE,
    document_id    TEXT      NOT NULL,
    position       INTEGER   NOT NULL,
    clicked_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_search_queries_tenant_created ON search_queries(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_search_queries_user ON search_queries(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_search_clicks_query ON search_clicks(query_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS search_clicks CASCADE;
DROP TABLE IF EXISTS search_queries CASCADE;
DROP TABLE IF EXISTS search_indices CASCADE;
-- +goose StatementEnd
