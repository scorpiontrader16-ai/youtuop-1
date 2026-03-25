# ╔══════════════════════════════════════════════════════════════════╗
# ║  المسار الكامل: scripts/setup-cert-manager-m5.sh                ║
# ║  الحالة: 🆕 جديد                                                ║
# ╚══════════════════════════════════════════════════════════════════╝
#!/usr/bin/env bash
# الاستخدام:
#   ./scripts/setup-cert-manager-m5.sh            # تثبيت كامل
#   ./scripts/setup-cert-manager-m5.sh --check    # فحص الشهادات
#   ./scripts/setup-cert-manager-m5.sh --install  # تثبيت cert-manager فقط
# المتطلبات: kubectl, helm v3+, setup-pki.sh سبق تشغيله
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.0}"
CERT_DIR="${CERT_DIR:-/tmp/youtuop-pki}"
NAMESPACE="${NAMESPACE:-platform}"

install_cert_manager() {
    log_info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update jetstack
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "${CERT_MANAGER_VERSION}" \
        --set installCRDs=true \
        --set global.leaderElection.namespace=cert-manager \
        --set prometheus.enabled=true \
        --set prometheus.servicemonitor.enabled=true \
        --wait --timeout=5m
    log_ok "cert-manager ${CERT_MANAGER_VERSION} installed"
}

upload_ca_secret() {
    log_info "Uploading Platform CA to cert-manager namespace..."
    if [[ ! -f "${CERT_DIR}/ca/ca.crt" ]] || [[ ! -f "${CERT_DIR}/ca/ca.key" ]]; then
        log_error "CA files not found in ${CERT_DIR}/ca/ — Run ./scripts/setup-pki.sh first."
    fi
    kubectl delete secret platform-ca-secret --namespace cert-manager --ignore-not-found=true
    kubectl create secret generic platform-ca-secret \
        --namespace cert-manager \
        --from-file=tls.crt="${CERT_DIR}/ca/ca.crt" \
        --from-file=tls.key="${CERT_DIR}/ca/ca.key"
    log_ok "platform-ca-secret created in cert-manager namespace"
}

apply_cluster_issuer() {
    log_info "Applying ClusterIssuer platform-ca-issuer..."
    kubectl apply -f infra/cert-manager/cluster-issuer.yaml
    local retries=12
    while [[ $retries -gt 0 ]]; do
        local status
        status=$(kubectl get clusterissuer platform-ca-issuer \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$status" == "True" ]]; then
            log_ok "ClusterIssuer platform-ca-issuer is Ready"
            return 0
        fi
        log_info "Waiting for ClusterIssuer... (${retries} retries left)"
        sleep 5
        retries=$((retries - 1))
    done
    log_error "ClusterIssuer not ready after 60s — check: kubectl describe clusterissuer platform-ca-issuer"
}

check_certificates() {
    log_info "Checking Certificates in namespace ${NAMESPACE}..."
    echo ""
    kubectl get certificates -n "${NAMESPACE}" \
        -o custom-columns="NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRY:.status.notAfter" \
        2>/dev/null || log_warn "No certificates found"
    echo ""
    log_info "Details: kubectl describe certificate <name> -n ${NAMESPACE}"
}

main() {
    local mode="${1:-setup}"
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  youtuop-1 — M5 cert-manager Setup"
    echo "══════════════════════════════════════════════════"
    echo ""
    case "$mode" in
        --check)   check_certificates ;;
        --install) install_cert_manager ;;
        setup|*)
            install_cert_manager
            upload_ca_secret
            apply_cluster_issuer
            echo ""
            log_ok "M5 cert-manager bootstrap complete!"
            log_info "Verify: ./scripts/setup-cert-manager-m5.sh --check"
            ;;
    esac
}

main "${1:-setup}"
