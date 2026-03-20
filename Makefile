# ============================================================
# Platform Infrastructure — Makefile
# ============================================================
.DEFAULT_GOAL := help

# ─── Variables ───────────────────────────────────────────
SCHEMA_REGISTRY_URL ?= http://localhost:18081
PROTO_DIR           ?= ./proto
POSTGRES_DSN        ?= postgres://platform:platform@localhost:5432/platform?sslmode=disable

# ─── Help ─────────────────────────────────────────────────
.PHONY: help
help: ## Show all available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ─── M1: Dev / Build / Test ───────────────────────────────
.PHONY: dev build test proto

dev: ## Start all services + migrations + schema registration
	docker compose up -d
	@echo "Waiting for services to be healthy..."
	@sleep 15
	@$(MAKE) db-migrate
	@$(MAKE) schema-register
	@echo ""
	@echo "✅ All services ready:"
	@echo "   Redpanda Console : http://localhost:8080"
	@echo "   ClickHouse       : http://localhost:8123/play"
	@echo "   MinIO            : http://localhost:9001"
	@echo "   Grafana          : http://localhost:3000"
	@echo "   Ingestion HTTP   : http://localhost:9091"
	@echo "   Processing       : http://localhost:9093/metrics"

build: ## Build all services
	docker compose build

test: ## Run unit tests (Go + Rust)
	cd services/ingestion && go test ./...
	cd services/processing && cargo test

proto: ## Generate code from proto files (requires buf)
	buf generate

# ─── Schema Registry ──────────────────────────────────────
.PHONY: schema-register schema-list

schema-register: ## Register all proto schemas
	SCHEMA_REGISTRY_URL=$(SCHEMA_REGISTRY_URL) \
	PROTO_DIR=$(PROTO_DIR) \
	bash ./scripts/register-schemas.sh

schema-list: ## List all registered subjects
	@curl -s $(SCHEMA_REGISTRY_URL)/subjects | jq .

# ─── Services ─────────────────────────────────────────────
.PHONY: up down logs status health

up: dev ## Alias for dev (start all services)

down: ## Stop all services
	docker compose down

logs: ## Show logs for all services
	docker compose logs -f

status: ## Show health status of all services
	@echo "=== Redpanda ==="
	@curl -sf http://localhost:9644/v1/cluster/health || echo "  DOWN"
	@echo "=== ClickHouse ==="
	@curl -sf http://localhost:8123/ping && echo "  UP" || echo "  DOWN"
	@echo "=== MinIO ==="
	@curl -sf http://localhost:9000/minio/health/live && echo "  UP" || echo "  DOWN"
	@echo "=== Schema Registry ==="
	@curl -sf http://localhost:18081/subjects > /dev/null && echo "  UP" || echo "  DOWN"
	@echo "=== Postgres ==="
	@pg_isready -h localhost -p 5432 -U platform && echo "  UP" || echo "  DOWN"
	@echo "=== Redis ==="
	@redis-cli -h localhost ping || echo "  DOWN"
	@echo "=== Grafana ==="
	@curl -sf http://localhost:3000/api/health > /dev/null && echo "  UP" || echo "  DOWN"
	@echo "=== Ingestion ==="
	@curl -sf http://localhost:9091/healthz && echo "  UP" || echo "  DOWN"
	@echo "=== Processing ==="
	@curl -sf http://localhost:9093/healthz && echo "  UP" || echo "  DOWN"

health: status ## Alias for status

# ─── Database Migrations ──────────────────────────────────
.PHONY: db-migrate db-migrate-down db-migrate-status

db-migrate: ## Run Postgres migrations
	GOOSE_MIGRATION_DIR=./services/ingestion/internal/postgres/migrations \
	GOOSE_DBSTRING=$(POSTGRES_DSN) \
	bash ./scripts/migrate.sh up

db-migrate-down: ## Rollback last migration
	GOOSE_MIGRATION_DIR=./services/ingestion/internal/postgres/migrations \
	GOOSE_DBSTRING=$(POSTGRES_DSN) \
	bash ./scripts/migrate.sh down

db-migrate-status: ## Show migrations status
	GOOSE_MIGRATION_DIR=./services/ingestion/internal/postgres/migrations \
	GOOSE_DBSTRING=$(POSTGRES_DSN) \
	bash ./scripts/migrate.sh status

# ─── Integration Tests ────────────────────────────────────
.PHONY: test-schema test-clickhouse test-postgres test-integration

test-schema: ## Integration tests for schema registry
	SCHEMA_REGISTRY_URL=$(SCHEMA_REGISTRY_URL) \
	go test -tags=integration -v -timeout=60s \
		./services/ingestion/internal/schemaregistry/...

test-clickhouse: ## Integration tests for ClickHouse
	go test -tags=integration -v -timeout=60s \
		./services/ingestion/internal/clickhouse/...

test-postgres: ## Integration tests for Postgres
	POSTGRES_DSN=$(POSTGRES_DSN) \
	go test -tags=integration -v -timeout=60s \
		./services/ingestion/internal/postgres/...

test-integration: test-schema test-clickhouse test-postgres ## Run all integration tests
	@echo "✅ All integration tests passed"

# ─── Tiering ──────────────────────────────────────────────
.PHONY: tiering-run

tiering-run: ## Run tiering job manually (ClickHouse → MinIO)
	cd services/ingestion && \
		POSTGRES_HOST=localhost \
		MINIO_ENDPOINT=localhost:9000 \
		go run ./cmd/tiering/...

# ─── Lint ─────────────────────────────────────────────────
.PHONY: lint

lint: ## Run all linters (Go + Rust)
	cd services/ingestion && golangci-lint run ./...
	cd services/processing && cargo clippy -- -D warnings
