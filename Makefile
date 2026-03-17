# ─────────────────────────────────────────────────────────────────────────────
# Platform Makefile
# Usage: make <target>
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: help dev down logs logs-ingestion logs-processing \
        proto proto-lint proto-breaking \
        build-go build-rust build-rust-dev build \
        test-go test-rust test \
        lint-go lint-rust lint \
        fmt-go fmt-rust fmt \
        deny-rust health clean

help:
	@echo ""
	@echo "  Platform — Available Commands"
	@echo "  ─────────────────────────────────────────────"
	@echo "  make dev          Start all services locally"
	@echo "  make down         Stop all services"
	@echo "  make logs         Tail all logs"
	@echo "  make proto        Generate code from .proto files"
	@echo "  make build-go     Build Go ingestion service"
	@echo "  make build-rust   Build Rust processing service"
	@echo "  make test-go      Run Go tests"
	@echo "  make test-rust    Run Rust tests"
	@echo "  make lint         Run all linters"
	@echo "  make fmt          Format all code"
	@echo "  make health       Check all services health"
	@echo "  make clean        Remove build artifacts"
	@echo ""

# ── Local Development ─────────────────────────────────────────────────────
dev:
	docker compose up -d
	@echo ""
	@echo "  Services running:"
	@echo "  Redpanda Console   → http://localhost:8080"
	@echo "  Ingestion HTTP     → http://localhost:9091"
	@echo "  Ingestion gRPC     → localhost:8090"
	@echo "  Processing gRPC    → localhost:50051"
	@echo "  Processing metrics → http://localhost:9093/metrics"
	@echo "  Postgres           → localhost:5432"
	@echo "  Redis              → localhost:6379"
	@echo ""

down:
	docker compose down -v

logs:
	docker compose logs -f

logs-ingestion:
	docker compose logs -f ingestion

logs-processing:
	docker compose logs -f processing

# ── Proto ─────────────────────────────────────────────────────────────────
proto:
	cd proto && buf generate
	@echo "Proto generation complete"

proto-lint:
	cd proto && buf lint

proto-breaking:
	cd proto && buf breaking --against '.git#branch=main'

# ── Go ────────────────────────────────────────────────────────────────────
# main.go lives at services/ingestion/main.go — build target is . (package root)
build-go:
	cd services/ingestion && \
	CGO_ENABLED=0 go build \
		-ldflags="-s -w -X main.version=$$(git rev-parse --short HEAD)" \
		-trimpath \
		-o bin/server \
		.

test-go:
	cd services/ingestion && go test ./... -timeout 60s -race

lint-go:
	cd services/ingestion && go vet ./...

fmt-go:
	cd services/ingestion && gofmt -w .

# ── Rust ─────────────────────────────────────────────────────────────────
build-rust:
	cd services/processing && cargo build --release

build-rust-dev:
	cd services/processing && cargo build

test-rust:
	cd services/processing && cargo test

lint-rust:
	cd services/processing && cargo clippy -- -D warnings

fmt-rust:
	cd services/processing && cargo fmt

deny-rust:
	cd services/processing && cargo deny check

# ── Combined ──────────────────────────────────────────────────────────────
build: build-go build-rust

test: test-go test-rust

lint: lint-go lint-rust proto-lint

fmt: fmt-go fmt-rust

# ── Health checks ─────────────────────────────────────────────────────────
health:
	@echo "── Ingestion ──────────────────────────────────"
	@curl -sf http://localhost:9091/healthz && echo " ✅ live"  || echo " ❌ down"
	@curl -sf http://localhost:9091/readyz  && echo " ✅ ready" || echo " ❌ not ready"
	@echo "── Processing ─────────────────────────────────"
	@curl -sf http://localhost:9093/healthz && echo " ✅ live"  || echo " ❌ down"
	@curl -sf http://localhost:9093/readyz  && echo " ✅ ready" || echo " ❌ not ready"
	@echo "── Metrics ────────────────────────────────────"
	@curl -sf http://localhost:9093/metrics | head -5 && echo "..." || echo " ❌ no metrics"

# ── Cleanup ───────────────────────────────────────────────────────────────
clean:
	rm -rf services/ingestion/bin
	cd services/processing && cargo clean
