#!/usr/bin/env bash
# scripts/migrate.sh
# يشغّل Goose migrations على Postgres
#
# الاستخدام:
#   ./scripts/migrate.sh             # up (default)
#   ./scripts/migrate.sh up
#   ./scripts/migrate.sh down
#   ./scripts/migrate.sh status
#   ./scripts/migrate.sh reset       # down-to + up (dev فقط)

set -euo pipefail

COMMAND="${1:-up}"
MIGRATIONS_DIR="${GOOSE_MIGRATION_DIR:-./migrations/postgres}"
DSN="${GOOSE_DBSTRING:-postgres://platform:platform@localhost:5432/platform?sslmode=disable}"

echo "🐘 Postgres Migrations"
echo "   Command : $COMMAND"
echo "   Dir     : $MIGRATIONS_DIR"
echo ""

# ─── تحقق من goose ────────────────────────────────────────────────────────
if ! command -v goose &>/dev/null; then
  echo "❌ goose not found"
  echo "   Install: go install github.com/pressly/goose/v3/cmd/goose@latest"
  exit 1
fi

# ─── انتظر Postgres ───────────────────────────────────────────────────────
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

# ─── تنفيذ الـ command ────────────────────────────────────────────────────
case "$COMMAND" in
  up)
    wait_for_postgres
    echo "⬆️  Running migrations UP..."
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" up
    echo "✅ Migrations applied"
    ;;

  down)
    echo "⬇️  Running migration DOWN (one step)..."
    goose -dir "$MIGRATIONS_DIR" postgres "$DSN" down
    echo "✅ Rolled back one migration"
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
