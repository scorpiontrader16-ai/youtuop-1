# ============================================================
# Platform Infrastructure — Makefile
# ============================================================

.DEFAULT_GOAL := help

# ─── Variables ───────────────────────────────────────────
SCHEMA_REGISTRY_URL ?= http://localhost:8081
PROTO_DIR           ?= ./proto
POSTGRES_DSN        ?= postgres://platform:platform@localhost:5432/platform?sslmode=disable

# ─── Help ─────────────────────────────────────────────────
.PHONY: help
help: ## يعرض كل الـ targets المتاحة
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ─── M1: Dev / Build / Test ───────────────────────────────
.PHONY: dev build test proto

dev: ## يشغّل كل الـ services محلياً
	docker compose up -d

build: ## يبني كل الـ services
	docker compose build

test: ## يشغّل الـ unit tests
	cd services/ingestion  && go test ./...
	cd services/processing && cargo test

proto: ## يولد الكود من الـ proto files (يحتاج buf)
	buf generate

# ─── Schema Registry ──────────────────────────────────────
.PHONY: schema-register schema-list

schema-register: ## يسجل كل الـ proto schemas
	SCHEMA_REGISTRY_URL=$(SCHEMA_REGISTRY_URL) \
	PROTO_DIR=$(PROTO_DIR) \
	bash ./scripts/register-schemas.sh

schema-list: ## يعرض كل الـ registered subjects
	@curl -s $(SCHEMA_REGISTRY_URL)/subjects | jq .

# ─── M4 Services ─────────────────────────────────────────
.PHONY: m4-up m4-down m4-logs m4-status

m4-up: ## يشغل M4 services كاملة (ClickHouse + MinIO)
	docker compose -f docker-compose.yml -f infra/docker-compose.m4.yml up -d
	@echo "⏳ Waiting for services to be healthy..."
	@sleep 10
	@$(MAKE) db-migrate
	@$(MAKE) schema-register
	@echo ""
	@echo "✅ M4 ready"
	@echo "   ClickHouse : http://localhost:8123/play"
	@echo "   MinIO      : http://localhost:9001"
	@echo "   Redpanda   : http://localhost:8080"

m4-down: ## يوقف M4 services
	docker compose -f docker-compose.yml -f infra/docker-compose.m4.yml down

m4-logs: ## يعرض logs الـ M4 services
	docker compose -f docker-compose.yml -f infra/docker-compose.m4.yml \
		logs -f clickhouse minio

m4-status: ## يعرض حالة كل M4 services
	@echo "=== ClickHouse ==="
	@curl -sf http://localhost:8123/ping && echo " ✅ UP" || echo " ❌ DOWN"
	@echo "=== MinIO ==="
	@curl -sf http://localhost:9000/minio/health/live && echo " ✅ UP" || echo " ❌ DOWN"
	@echo "=== Schema Registry ==="
	@curl -sf http://localhost:8081/subjects > /dev/null && echo " ✅ UP" || echo " ❌ DOWN"

# ─── Database Migrations ──────────────────────────────────
.PHONY: db-migrate db-migrate-down db-migrate-status

db-migrate: ## يشغّل Postgres migrations
	GOOSE_MIGRATION_DIR=./services/ingestion/internal/postgres/migrations \
	GOOSE_DBSTRING=$(POSTGRES_DSN) \
	bash ./scripts/migrate.sh up

db-migrate-down: ## يتراجع عن آخر migration
	GOOSE_MIGRATION_DIR=./services/ingestion/internal/postgres/migrations \
	GOOSE_DBSTRING=$(POSTGRES_DSN) \
	bash ./scripts/migrate.sh down

db-migrate-status: ## يعرض حالة الـ migrations
	GOOSE_MIGRATION_DIR=./services/ingestion/internal/postgres/migrations \
	GOOSE_DBSTRING=$(POSTGRES_DSN) \
	bash ./scripts/migrate.sh status

# ─── Integration Tests ────────────────────────────────────
.PHONY: test-schema test-clickhouse test-postgres test-integration

test-schema: ## integration tests للـ schema registry
	SCHEMA_REGISTRY_URL=$(SCHEMA_REGISTRY_URL) \
	go test -tags=integration -v -timeout=60s \
		./services/ingestion/internal/schemaregistry/...

test-clickhouse: ## integration tests للـ ClickHouse
	go test -tags=integration -v -timeout=60s \
		./services/ingestion/internal/clickhouse/...

test-postgres: ## integration tests للـ Postgres
	POSTGRES_DSN=$(POSTGRES_DSN) \
	go test -tags=integration -v -timeout=60s \
		./services/ingestion/internal/postgres/...

test-integration: test-schema test-clickhouse test-postgres ## كل الـ integration tests
	@echo "✅ All integration tests passed"

# ─── Tiering ─────────────────────────────────────────────
.PHONY: tiering-run

tiering-run: ## يشغّل tiering job يدوياً
	cd services/ingestion && \
	POSTGRES_HOST=localhost \
	MINIO_ENDPOINT=localhost:9000 \
	go run ./cmd/tiering/...
