#!/usr/bin/env bash
# ============================================================
# scripts/vault-setup.sh
# Day-2 Vault Initialization & Bootstrap
#
# الاستخدام:
#   ./scripts/vault-setup.sh init       # تهيئة Vault لأول مرة
#   ./scripts/vault-setup.sh unseal     # فك القفل بعد restart
#   ./scripts/vault-setup.sh bootstrap  # إنشاء vault_admin + K8s secret
#   ./scripts/vault-setup.sh status     # فحص الحالة
#
# المتطلبات: kubectl, vault (CLI), psql, aws (CLI), jq
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
AWS_SECRET_NAME="${AWS_SECRET_NAME:-platform/vault-bootstrap}"
PORT_FORWARD_PID=""

check_prerequisites() {
    local missing=0
    for cmd in kubectl vault psql aws jq openssl; do
        command -v "$cmd" &>/dev/null && log_ok "$cmd found" || { log_error "Missing: $cmd"; missing=$((missing+1)); }
    done
    kubectl cluster-info &>/dev/null && log_ok "cluster connected" || { log_error "kubectl: cannot connect"; missing=$((missing+1)); }
    [ "$missing" -gt 0 ] && { log_error "Missing $missing prerequisites"; exit 1; }
}

setup_port_forward() {
    log_info "Setting up port-forward to vault..."
    kubectl port-forward -n "$VAULT_NAMESPACE" svc/vault 8200:8200 &
    PORT_FORWARD_PID=$!
    sleep 3
    export VAULT_ADDR="http://127.0.0.1:8200"
    log_ok "Port-forward active (PID: $PORT_FORWARD_PID)"
}

cleanup() { [ -n "$PORT_FORWARD_PID" ] && kill "$PORT_FORWARD_PID" 2>/dev/null || true; }

vault_init() {
    if vault status 2>/dev/null | grep -q "Initialized.*true"; then
        log_warn "Vault already initialized — skipping"; return 0
    fi

    INIT_OUTPUT=$(vault operator init -key-shares=5 -key-threshold=3 -format=json)
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
    K1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
    K2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
    K3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
    K4=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[3]')
    K5=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[4]')

    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "CRITICAL: احفظ هذه المفاتيح فوراً في مكان آمن"
    echo "Unseal Key 1: $K1"
    echo "Unseal Key 2: $K2"
    echo "Unseal Key 3: $K3"
    echo "Unseal Key 4: $K4"
    echo "Unseal Key 5: $K5"
    echo "Root Token:   $ROOT_TOKEN"
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    aws secretsmanager put-secret-value \
        --secret-id "$AWS_SECRET_NAME" \
        --secret-string "$(jq -n \
            --arg t "$ROOT_TOKEN" --arg k1 "$K1" --arg k2 "$K2" --arg k3 "$K3" \
            '{root_token:$t,unseal_key_1:$k1,unseal_key_2:$k2,unseal_key_3:$k3}')" \
        2>/dev/null && log_ok "Keys saved to AWS SM: $AWS_SECRET_NAME" \
        || log_warn "AWS SM save failed — save keys manually!"
}

vault_unseal() {
    vault status 2>/dev/null | grep -q "Sealed.*false" && { log_ok "Already unsealed"; return 0; }
    SECRET=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text)
    vault operator unseal "$(echo "$SECRET" | jq -r '.unseal_key_1')"
    vault operator unseal "$(echo "$SECRET" | jq -r '.unseal_key_2')"
    vault operator unseal "$(echo "$SECRET" | jq -r '.unseal_key_3')"
    log_ok "Vault unsealed"
}

bootstrap() {
    SECRET=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text)
    ROOT_TOKEN=$(echo "$SECRET" | jq -r '.root_token')
    export VAULT_TOKEN="$ROOT_TOKEN"

    [ -z "${POSTGRES_ADMIN_URL:-}" ] && { log_error "POSTGRES_ADMIN_URL not set"; exit 1; }

    VAULT_DB_PASSWORD=$(openssl rand -base64 32)
    log_info "Creating vault_admin in Postgres..."
    psql "$POSTGRES_ADMIN_URL" << SQL
CREATE USER vault_admin WITH PASSWORD '${VAULT_DB_PASSWORD}' CREATEROLE;
GRANT auth_role, billing_role, analytics_role, control_plane_role,
      developer_portal_role, feature_flags_role, hydration_role, ingestion_role,
      jobs_role, ml_engine_role, notifications_role, processing_role,
      realtime_role, search_role, tenant_operator_role
TO vault_admin WITH ADMIN OPTION;
SELECT usename, usecreaterole FROM pg_user WHERE usename = 'vault_admin';
SQL
    log_ok "vault_admin created"

    log_info "Creating vault-bootstrap-token secret..."
    kubectl create secret generic vault-bootstrap-token \
        --namespace "$VAULT_NAMESPACE" \
        --from-literal="token=${ROOT_TOKEN}" \
        --from-literal="db_admin_user=vault_admin" \
        --from-literal="db_admin_password=${VAULT_DB_PASSWORD}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_ok "vault-bootstrap-token created"

    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_warn "NEXT STEPS:"
    log_warn "  1. ArgoCD سيُشغِّل الـ Job تلقائياً (PostSync hook)"
    log_warn "  2. راقب الـ Job:"
    log_warn "     kubectl logs -n vault job/vault-auth-config -f"
    log_warn "  3. بعد نجاح الـ Job:"
    log_warn "     kubectl delete secret vault-bootstrap-token -n vault"
    log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

vault_status() {
    vault status || true
    echo ""; log_info "Kubernetes Auth:"; vault auth list 2>/dev/null | grep kubernetes || echo "  not configured"
    echo ""; log_info "Secrets Engines:"; vault secrets list 2>/dev/null | grep database || echo "  not configured"
    echo ""; log_info "Policies:"; vault policy list 2>/dev/null | grep platform || echo "  not created"
    echo ""; log_info "Bootstrap Secret:"
    kubectl get secret vault-bootstrap-token -n "$VAULT_NAMESPACE" &>/dev/null \
        && log_warn "vault-bootstrap-token EXISTS — delete after bootstrap!" \
        || log_ok "vault-bootstrap-token: not present (good)"
}

main() {
    echo ""; echo "=========================================="; echo "  youtuop-1 Vault Setup — GAP-07"; echo "=========================================="; echo ""
    check_prerequisites
    setup_port_forward
    trap cleanup EXIT
    case "${1:-status}" in
        init)      vault_init ;;
        unseal)    vault_unseal ;;
        bootstrap) vault_unseal && bootstrap ;;
        status)    vault_status ;;
        *) log_error "Usage: $0 {init|unseal|bootstrap|status}"; exit 1 ;;
    esac
}
main "${1:-status}"
