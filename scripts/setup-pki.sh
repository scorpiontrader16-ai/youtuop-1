#!/usr/bin/env bash
# ============================================================
# scripts/setup-pki.sh
# إعداد PKI للـ mTLS بين الخدمات
#
# الاستخدام:
#   ./scripts/setup-pki.sh              # إعداد كامل
#   ./scripts/setup-pki.sh --check      # فحص الشهادات فقط
#   ./scripts/setup-pki.sh --renew      # تجديد الشهادات
#
# المتطلبات: kubectl, openssl, vault (CLI)
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Config ────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-platform}"
CERT_DIR="${CERT_DIR:-/tmp/youtuop-pki}"
CA_VALIDITY_DAYS="${CA_VALIDITY_DAYS:-3650}"   # 10 سنين للـ CA
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-365}" # سنة للـ service certs
VAULT_PKI_PATH="${VAULT_PKI_PATH:-pki}"
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"

# الخدمات اللي محتاجة mTLS
SERVICES=(
    "ingestion"
    "processing"
    "redpanda"
    "clickhouse"
    "postgres"
)

# ── Check Prerequisites ───────────────────────────────────
check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing=0

    for cmd in kubectl openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Missing: $cmd"
            missing=$((missing + 1))
        else
            log_ok "$cmd found"
        fi
    done

    if ! kubectl cluster-info &>/dev/null; then
        log_error "kubectl: cannot connect to cluster"
        missing=$((missing + 1))
    else
        log_ok "kubectl: cluster connected"
    fi

    if [ "$missing" -gt 0 ]; then
        log_error "Missing $missing prerequisites. Aborting."
        exit 1
    fi
}

# ── Create CA ─────────────────────────────────────────────
create_ca() {
    log_info "Creating Certificate Authority..."
    mkdir -p "$CERT_DIR/ca" "$CERT_DIR/certs"

    if [ -f "$CERT_DIR/ca/ca.crt" ]; then
        log_warn "CA already exists. Use --renew to recreate."
        return 0
    fi

    # إنشاء الـ CA private key
    openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/ca/ca.key"

    # إنشاء الـ CA certificate
    openssl req -new -x509 \
        -key "$CERT_DIR/ca/ca.key" \
        -out "$CERT_DIR/ca/ca.crt" \
        -days "$CA_VALIDITY_DAYS" \
        -subj "/CN=youtuop-platform-ca/O=youtuop/OU=platform" \
        -extensions v3_ca \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    log_ok "CA created: $CERT_DIR/ca/ca.crt"
}

# ── Create Service Certificate ────────────────────────────
create_service_cert() {
    local service="$1"
    log_info "Creating cert for: $service"

    local cert_dir="$CERT_DIR/certs/$service"
    mkdir -p "$cert_dir"

    # Private key
    openssl ecparam -name prime256v1 -genkey -noout -out "$cert_dir/tls.key"

    # CSR config — يشمل كل الـ DNS names المحتملة
    cat > "$cert_dir/csr.conf" << EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
CN = $service
O = youtuop
OU = platform

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $service
DNS.2 = $service.$NAMESPACE
DNS.3 = $service.$NAMESPACE.svc
DNS.4 = $service.$NAMESPACE.svc.cluster.local
DNS.5 = ${service}-stable
DNS.6 = ${service}-stable.$NAMESPACE.svc.cluster.local
IP.1 = 127.0.0.1
EOF

    # CSR
    openssl req -new \
        -key "$cert_dir/tls.key" \
        -out "$cert_dir/tls.csr" \
        -config "$cert_dir/csr.conf"

    # Sign بالـ CA
    openssl x509 -req \
        -in "$cert_dir/tls.csr" \
        -CA "$CERT_DIR/ca/ca.crt" \
        -CAkey "$CERT_DIR/ca/ca.key" \
        -CAcreateserial \
        -out "$cert_dir/tls.crt" \
        -days "$CERT_VALIDITY_DAYS" \
        -extensions v3_req \
        -extfile "$cert_dir/csr.conf"

    log_ok "Cert created for $service (valid $CERT_VALIDITY_DAYS days)"
}

# ── Upload to Kubernetes Secrets ─────────────────────────
upload_to_k8s() {
    local service="$1"
    local cert_dir="$CERT_DIR/certs/$service"
    local secret_name="${service}-mtls-certs"

    log_info "Uploading certs for $service to K8s..."

    # حذف الـ secret القديم لو موجود
    kubectl delete secret "$secret_name" \
        -n "$NAMESPACE" \
        --ignore-not-found=true

    # رفع الـ secret الجديد
    kubectl create secret generic "$secret_name" \
        -n "$NAMESPACE" \
        --from-file=tls.crt="$cert_dir/tls.crt" \
        --from-file=tls.key="$cert_dir/tls.key" \
        --from-file=ca.crt="$CERT_DIR/ca/ca.crt"

    log_ok "Secret $secret_name created in namespace $NAMESPACE"
}

# ── Upload CA to all namespaces ───────────────────────────
upload_ca() {
    log_info "Uploading CA certificate to namespaces..."

    for ns in "$NAMESPACE" monitoring argocd; do
        if kubectl get namespace "$ns" &>/dev/null; then
            kubectl create configmap platform-ca \
                -n "$ns" \
                --from-file=ca.crt="$CERT_DIR/ca/ca.crt" \
                --dry-run=client -o yaml | kubectl apply -f -
            log_ok "CA uploaded to namespace: $ns"
        fi
    done
}

# ── Check Certificate Expiry ──────────────────────────────
check_certs() {
    log_info "Checking certificate expiry..."
    local warning_days=30

    for service in "${SERVICES[@]}"; do
        local secret="${service}-mtls-certs"
        if kubectl get secret "$secret" -n "$NAMESPACE" &>/dev/null; then
            local cert
            cert=$(kubectl get secret "$secret" -n "$NAMESPACE" \
                -o jsonpath='{.data.tls\.crt}' | base64 -d)

            local expiry
            expiry=$(echo "$cert" | openssl x509 -noout -enddate 2>/dev/null \
                | cut -d= -f2)

            local expiry_epoch
            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || \
                           date -j -f "%b %d %T %Y %Z" "$expiry" +%s)

            local now_epoch
            now_epoch=$(date +%s)

            local days_remaining
            days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [ "$days_remaining" -lt "$warning_days" ]; then
                log_warn "$service cert expires in $days_remaining days! ($expiry)"
            else
                log_ok "$service cert valid for $days_remaining days"
            fi
        else
            log_warn "$service: no cert found (secret $secret not found)"
        fi
    done
}

# ── Main ──────────────────────────────────────────────────
main() {
    local mode="${1:-setup}"

    echo ""
    echo "============================================"
    echo "  youtuop-1 PKI Setup — mTLS Configuration"
    echo "============================================"
    echo ""

    case "$mode" in
        --check)
            check_prerequisites
            check_certs
            ;;
        --renew)
            check_prerequisites
            log_info "Renewing all certificates..."
            rm -rf "$CERT_DIR"
            create_ca
            for service in "${SERVICES[@]}"; do
                create_service_cert "$service"
                upload_to_k8s "$service"
            done
            upload_ca
            check_certs
            log_ok "All certificates renewed!"
            ;;
        setup|*)
            check_prerequisites
            create_ca
            for service in "${SERVICES[@]}"; do
                create_service_cert "$service"
                upload_to_k8s "$service"
            done
            upload_ca
            check_certs
            echo ""
            log_ok "PKI setup complete!"
            log_info "Certificates stored in: $CERT_DIR"
            log_info "Run './scripts/setup-pki.sh --check' to verify anytime"
            echo ""
            ;;
    esac
}

main "${1:-setup}"
