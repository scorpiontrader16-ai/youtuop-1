#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  scripts/migrate-all-tenants.sh                                 ║
# ║  Multi-Tenant Migration — Enterprise Grade                      ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail
IFS=$'\n\t'

# ── Configuration ────────────────────────────────────────────────────
DB_HOST="${DB_HOST:-postgres.platform.svc.cluster.local}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-platform_admin}"
DB_NAME="${DB_NAME:-platform}"
DB_SSLMODE="${DB_SSLMODE:-require}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-services/auth/internal/postgres/migrations}"
DRY_RUN="${DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-info}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
PERFORMED_BY="${PERFORMED_BY:-migration-script}"

# ── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2; }

# ── Argument Parsing ─────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --dry-run)       DRY_RUN=true ;;
    --tenant=*)      SINGLE_TENANT="${arg#*=}" ;;
    --performed-by=*) PERFORMED_BY="${arg#*=}" ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--tenant=<slug>] [--performed-by=<actor>]"
      echo ""
      echo "  --dry-run              Show what would be migrated without executing"
      echo "  --tenant=<slug>        Migrate a single tenant only"
      echo "  --performed-by=<actor> Who is running the migration (for audit log)"
      exit 0
      ;;
    *) log_warn "Unknown argument: $arg" ;;
  esac
done

# ── DSN Builder ──────────────────────────────────────────────────────
build_dsn() {
  local schema="$1"
  echo "host=${DB_HOST} port=${DB_PORT} user=${DB_USER} dbname=${DB_NAME} sslmode=${DB_SSLMODE} search_path=${schema}"
}

# ── psql Helper ──────────────────────────────────────────────────────
run_psql() {
  PGPASSWORD="${PGPASSWORD:-}" psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    --no-password \
    "$@"
}

# ── Preflight Checks ─────────────────────────────────────────────────
preflight() {
  log_info "Running preflight checks..."

  if ! command -v goose &>/dev/null; then
    log_error "goose not found — install: go install github.com/pressly/goose/v3/cmd/goose@latest"
    exit 1
  fi

  if ! command -v psql &>/dev/null; then
    log_error "psql not found"
    exit 1
  fi

  if [[ ! -d "$MIGRATIONS_DIR" ]]; then
    log_error "Migrations directory not found: $MIGRATIONS_DIR"
    exit 1
  fi

  if ! run_psql -c "SELECT 1" &>/dev/null; then
    log_error "Cannot connect to database at ${DB_HOST}:${DB_PORT}"
    exit 1
  fi

  log_success "Preflight checks passed"
}

# ── Audit Log ────────────────────────────────────────────────────────
audit_log() {
  local tenant_id="$1"
  local action="$2"
  local details="${3:-{}}"

  run_psql -c "
    INSERT INTO tenant_audit_log (tenant_id, action, performed_by, details, performed_at)
    VALUES (
      '${tenant_id}',
      '${action}',
      '${PERFORMED_BY}',
      '${details}'::jsonb,
      NOW()
    );
  " &>/dev/null || log_warn "Could not write audit log for tenant ${tenant_id}"
}

# ── Migration with Retry ──────────────────────────────────────────────
migrate_tenant() {
  local slug="$1"
  local tenant_id="$2"
  local schema="tenant_${slug//-/_}"
  local attempt=0
  local dsn
  dsn="$(build_dsn "$schema")"

  log_info "Processing tenant: ${slug} (schema: ${schema})"

  # Verify schema exists
  local schema_exists
  schema_exists=$(run_psql -t -c \
    "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '${schema}';" \
    | tr -d ' \n')

  if [[ "$schema_exists" == "0" ]]; then
    log_warn "Schema '${schema}' does not exist — skipping tenant '${slug}'"
    audit_log "$tenant_id" "migration_skipped" \
      "{\"reason\":\"schema_not_found\",\"schema\":\"${schema}\"}"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would migrate schema: ${schema}"
    goose -dir="$MIGRATIONS_DIR" postgres "$dsn" status 2>/dev/null || true
    return 0
  fi

  # Retry loop
  while [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$((attempt + 1))
    log_info "  Attempt ${attempt}/${MAX_RETRIES} for ${slug}..."

    if goose -dir="$MIGRATIONS_DIR" postgres "$dsn" up 2>&1; then
      log_success "  Migrated: ${slug}"
      audit_log "$tenant_id" "migration_success" \
        "{\"schema\":\"${schema}\",\"attempt\":${attempt}}"
      return 0
    else
      local exit_code=$?
      log_warn "  Migration failed (attempt ${attempt}/${MAX_RETRIES}) exit_code=${exit_code}"
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        log_info "  Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      fi
    fi
  done

  log_error "  FAILED after ${MAX_RETRIES} attempts: ${slug}"
  audit_log "$tenant_id" "migration_failed" \
    "{\"schema\":\"${schema}\",\"attempts\":${MAX_RETRIES}}"
  return 1
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  log_info "═══════════════════════════════════════════"
  log_info "  Multi-Tenant Migration"
  log_info "  Host:    ${DB_HOST}:${DB_PORT}"
  log_info "  DB:      ${DB_NAME}"
  log_info "  DryRun:  ${DRY_RUN}"
  log_info "  Actor:   ${PERFORMED_BY}"
  log_info "═══════════════════════════════════════════"

  preflight

  # Get tenants
  local query
  if [[ -n "${SINGLE_TENANT:-}" ]]; then
    log_info "Single-tenant mode: ${SINGLE_TENANT}"
    query="SELECT id, slug FROM tenants WHERE slug='${SINGLE_TENANT}' AND status='active'"
  else
    query="SELECT id, slug FROM tenants WHERE status='active' ORDER BY created_at"
  fi

  local tenants
  tenants=$(run_psql -t -A -F'|' -c "$query" 2>/dev/null || true)

  if [[ -z "$tenants" ]]; then
    log_warn "No active tenants found"
    exit 0
  fi

  local total=0 succeeded=0 failed=0 skipped=0
  declare -a failed_tenants=()

  while IFS='|' read -r tenant_id slug; do
    [[ -z "$slug" ]] && continue
    total=$((total + 1))

    if migrate_tenant "$slug" "$tenant_id"; then
      succeeded=$((succeeded + 1))
    else
      failed=$((failed + 1))
      failed_tenants+=("$slug")
    fi
  done <<< "$tenants"

  # Summary
  log_info "═══════════════════════════════════════════"
  log_info "  Migration Summary"
  log_info "  Total:     ${total}"
  log_success "  Succeeded: ${succeeded}"
  [[ $failed -gt 0 ]] && log_error "  Failed:    ${failed}: ${failed_tenants[*]}"
  log_info "═══════════════════════════════════════════"

  [[ $failed -gt 0 ]] && exit 1
  exit 0
}

main "$@"
