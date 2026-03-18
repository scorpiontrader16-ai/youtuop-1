#!/usr/bin/env bash
# scripts/migrate.sh
# الاستخدام: ./scripts/migrate.sh [up|down|status|reset]

set -euo pipefail

COMMAND="${1:-up}"
# المسار الصح — نفس مكان الـ embed في client.go
MIGRATIONS_DIR="${GOOSE_MIGRATION_DIR:-./services/ingestion/internal/postgres/migrations}"
DSN="${GOOSE_DBSTRING:-postgres://platform:platform@localhost:5432/platform?sslmode=disable}"

echo "🐘 Postgres Migrations"
echo "   Command : $COMMAND"
echo "   Dir     : $MIGRATIONS_DIR"
echo ""

if ! command -v goose &>/dev/null; then
  echo "❌ goose not found"
  echo "   Install: go install github.com/pressly/goose/v3/cmd/goose@latest"
  exit 1
fi

wait_for_postgres() {
  echo "⏳ Waiting for Postgres..."
  local attempts=0
  until goose -dir "$MIGRATIONS_DIR" postgres "$DSN" status &>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      echo "❌ Postgres not ready after 60s"
      exit 1
    fi
    printf "   attempt %d/30...\r" "$attempts"
    sleep 2
  done
  echo "✅ Postgres is ready"
}

case "$COMMAND" in
  up)
    wait_for_postgres
    echo "⬆️  Running migrations UP..."
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" up
    echo "✅ Migrations applied"
    ;;
  down)
    echo "⬇️  Rolling back one migration..."
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" down
    echo "✅ Rolled back"
    ;;
  status)
    echo "📋 Migration status:"
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" status
    ;;
  reset)
    if [ "${ALLOW_RESET:-false}" != "true" ]; then
      echo "❌ reset is destructive — set ALLOW_RESET=true to proceed"
      exit 1
    fi
    echo "⚠️  Resetting all migrations..."
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" reset
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" up
    echo "✅ Reset complete"
    ;;
  *)
    echo "❌ Unknown command: $COMMAND"
    echo "   Usage: $0 [up|down|status|reset]"
    exit 1
    ;;
esac
