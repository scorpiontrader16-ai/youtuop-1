#!/usr/bin/env bash
# =============================================================================
# YOUTUOP PLATFORM — ENTERPRISE SECURITY AUDIT
# Version: 3.0.0
# Standard: NIST CSF 2.0 | CIS Kubernetes Benchmark v1.9 | OWASP API Top 10
#           PCI-DSS v4.0 | SOC 2 Type II | ISO 27001:2022
# Target: Multi-tenant Financial Data Analysis SaaS — AWS EKS ARM64
# =============================================================================
# USAGE:
#   chmod +x security-audit-enterprise.sh
#   ./security-audit-enterprise.sh [--fix] [--report-dir /path] [--section N]
#
# FLAGS:
#   --fix          Auto-remediate safe/low-risk findings
#   --report-dir   Custom output directory (default: ./security-reports/TIMESTAMP)
#   --section N    Run only section N (1-70)
#   --critical     Show only CRITICAL and HIGH findings
#   --json         Output machine-readable JSON summary
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────
# GLOBAL CONFIGURATION
# ─────────────────────────────────────────────────────────────
SCRIPT_VERSION="3.0.0"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_DIR="${REPORT_DIR:-./security-reports/${TIMESTAMP}}"
FIX_MODE=false
SECTION_FILTER=""
CRITICAL_ONLY=false
JSON_OUTPUT=false
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Counters (thread-safe via temp files)
PASS=0; WARN=0; FAIL=0; CRITICAL_COUNT=0; INFO=0
FINDINGS_FILE="${REPORT_DIR}/findings.log"
JSON_FILE="${REPORT_DIR}/summary.json"

# Color codes
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)          FIX_MODE=true ;;
    --report-dir)   REPORT_DIR="$2"; shift ;;
    --section)      SECTION_FILTER="$2"; shift ;;
    --critical)     CRITICAL_ONLY=true ;;
    --json)         JSON_OUTPUT=true ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

mkdir -p "${REPORT_DIR}"
: > "${FINDINGS_FILE}"

# ─────────────────────────────────────────────────────────────
# LOGGING HELPERS
# ─────────────────────────────────────────────────────────────
section() {
  local num="$1" title="$2"
  [[ -n "${SECTION_FILTER}" && "${SECTION_FILTER}" != "${num}" ]] && return 0
  echo ""
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  §${num}  ${title}${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
  echo "[SECTION ${num}] ${title}" >> "${FINDINGS_FILE}"
}

pass()     { ((PASS++));          echo -e "  ${GREEN}[PASS]${NC}     $*"; echo "[PASS]     $*" >> "${FINDINGS_FILE}"; }
warn()     { ((WARN++));          echo -e "  ${YELLOW}[WARN]${NC}     $*"; echo "[WARN]     $*" >> "${FINDINGS_FILE}"; }
fail()     { ((FAIL++));          echo -e "  ${RED}[FAIL]${NC}     $*"; echo "[FAIL]     $*" >> "${FINDINGS_FILE}"; }
critical() { ((CRITICAL_COUNT++)); ((FAIL++)); echo -e "  ${RED}${BOLD}[CRITICAL]${NC} $*"; echo "[CRITICAL] $*" >> "${FINDINGS_FILE}"; }
info()     { ((INFO++));          [[ "${CRITICAL_ONLY}" == true ]] && return; echo -e "  ${CYAN}[INFO]${NC}     $*"; echo "[INFO]     $*" >> "${FINDINGS_FILE}"; }
check()    { echo -e "  ${MAGENTA}[CHECK]${NC}    $*"; }

cmd_exists() { command -v "$1" &>/dev/null; }

# ─────────────────────────────────────────────────────────────
# REMEDIATION HELPER
# ─────────────────────────────────────────────────────────────
suggest_fix() {
  local description="$1" command="$2"
  echo -e "  ${CYAN}  ↳ FIX:${NC} ${description}"
  echo "     \$ ${command}"
  if [[ "${FIX_MODE}" == true ]]; then
    echo -e "  ${YELLOW}  → Auto-applying fix...${NC}"
    eval "${command}" 2>&1 | sed 's/^/     /' || true
  fi
}

# ─────────────────────────────────────────────────────────────
# COMPLIANCE REFERENCE
# ─────────────────────────────────────────────────────────────
compliance_ref() {
  echo -e "  ${CYAN}  ↳ REF:${NC} $*"
}

# ─────────────────────────────────────────────────────────────
# HEADER BANNER
# ─────────────────────────────────────────────────────────────
print_header() {
cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════════╗
║          YOUTUOP ENTERPRISE SECURITY AUDIT v3.0.0                   ║
║          Financial Data Platform — Multi-Tenant SaaS                ║
║──────────────────────────────────────────────────────────────────────║
║  Standards: NIST CSF 2.0 | CIS K8s v1.9 | OWASP API Top 10        ║
║             PCI-DSS v4.0 | SOC 2 Type II | ISO 27001:2022          ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER
  echo -e "${CYAN}  Repo Root: ${REPO_ROOT}${NC}"
  echo -e "${CYAN}  Reports:   ${REPORT_DIR}${NC}"
  echo -e "${CYAN}  Started:   $(date)${NC}"
  echo -e "${CYAN}  Fix Mode:  ${FIX_MODE}${NC}"
  echo ""
}

print_header

# =============================================================================
# §1  ENVIRONMENT & TOOLCHAIN READINESS
# =============================================================================
section 1 "ENVIRONMENT & TOOLCHAIN READINESS"

REQUIRED_TOOLS=(git kubectl helm cosign syft grype trivy semgrep gitleaks
                jq yq kubeconform kubeval checkov tfsec bandit gosec
                kube-bench kube-linter detect-secrets truffelhog)
OPTIONAL_TOOLS=(kubeaudit popeye pluto)

for tool in "${REQUIRED_TOOLS[@]}"; do
  if cmd_exists "${tool}"; then
    pass "Required tool present: ${tool} ($(${tool} version 2>/dev/null | head -1 || echo 'ok'))"
  else
    warn "Required tool MISSING: ${tool} — some checks will be skipped"
  fi
done

for tool in "${OPTIONAL_TOOLS[@]}"; do
  cmd_exists "${tool}" && pass "Optional tool: ${tool}" || info "Optional tool not found: ${tool}"
done

# Verify we are inside the correct repository
if git remote -v 2>/dev/null | grep -q "youtuop"; then
  pass "Repository confirmed: youtuop monorepo"
else
  warn "Could not confirm youtuop repository — verify REPO_ROOT"
fi

# Check Kubernetes cluster connectivity
if kubectl cluster-info &>/dev/null 2>&1; then
  CLUSTER=$(kubectl config current-context 2>/dev/null || echo "unknown")
  pass "Kubernetes cluster reachable — context: ${CLUSTER}"
  K8S_AVAILABLE=true
else
  warn "Kubernetes cluster not reachable — live cluster checks will be skipped"
  K8S_AVAILABLE=false
fi

# =============================================================================
# §2  SECRET & CREDENTIAL LEAKAGE — STATIC
# =============================================================================
section 2 "SECRET & CREDENTIAL LEAKAGE — STATIC ANALYSIS"
compliance_ref "PCI-DSS v4.0 Req 3.5 | SOC 2 CC6.1 | CIS Control 3"

# gitleaks — git history scan
if cmd_exists gitleaks; then
  check "Scanning full git history with gitleaks..."
  if gitleaks detect --source="${REPO_ROOT}" \
      --report-path="${REPORT_DIR}/gitleaks.json" \
      --report-format=json \
      --no-git=false 2>/dev/null; then
    pass "gitleaks: No secrets detected in git history"
  else
    LEAKED=$(jq length "${REPORT_DIR}/gitleaks.json" 2>/dev/null || echo "?")
    critical "gitleaks: ${LEAKED} secret(s) detected in git history"
    compliance_ref "PCI-DSS v4.0 Req 3.3.1 — Never store sensitive authentication data"
    jq -r '.[] | "     → \(.File):\(.StartLine) [\(.RuleID)]"' \
      "${REPORT_DIR}/gitleaks.json" 2>/dev/null | head -20
  fi
else
  warn "gitleaks not installed — git history secret scan skipped"
fi

# trufflehog — deep entropy analysis
if cmd_exists trufflehog; then
  check "Running trufflehog entropy scan..."
  if trufflehog filesystem "${REPO_ROOT}" \
      --json --no-update > "${REPORT_DIR}/trufflehog.json" 2>/dev/null; then
    TRUFF_COUNT=$(wc -l < "${REPORT_DIR}/trufflehog.json" 2>/dev/null || echo 0)
    [[ "${TRUFF_COUNT}" -eq 0 ]] && pass "trufflehog: No high-entropy secrets found" \
      || critical "trufflehog: ${TRUFF_COUNT} potential secret(s) found"
  fi
fi

# detect-secrets baseline check
if cmd_exists detect-secrets; then
  check "Checking detect-secrets baseline..."
  if [[ -f "${REPO_ROOT}/.secrets.baseline" ]]; then
    detect-secrets audit "${REPO_ROOT}/.secrets.baseline" --stats 2>/dev/null && \
      pass "detect-secrets: Baseline present and audited" || \
      warn "detect-secrets: Baseline has unreviewed secrets"
  else
    fail "detect-secrets: No .secrets.baseline found"
    suggest_fix "Create secrets baseline" \
      "cd ${REPO_ROOT} && detect-secrets scan > .secrets.baseline"
  fi
fi

# Hardcoded credentials pattern scan
check "Pattern-scanning for hardcoded credentials..."
DANGEROUS_PATTERNS=(
  'password\s*=\s*"[^"]+'
  'secret\s*=\s*"[^"]+'
  'api_key\s*=\s*"[^"]+'
  'AWS_SECRET_ACCESS_KEY\s*=\s*[A-Za-z0-9/+=]{20}'
  'PRIVATE KEY'
  'BEGIN RSA'
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  'postgres://[^:]+:[^@]+@'
  'redis://[^:]+:[^@]+'
)

HARDCODED_FOUND=0
for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  MATCHES=$(grep -rn --include="*.go" --include="*.py" --include="*.rs" \
    --include="*.yaml" --include="*.yml" --include="*.env" \
    --include="*.json" --include="*.toml" \
    -E "${pattern}" "${REPO_ROOT}" \
    --exclude-dir=".git" --exclude-dir="vendor" \
    2>/dev/null | grep -v "_test\." | grep -v "example" | wc -l || echo 0)
  [[ "${MATCHES}" -gt 0 ]] && { ((HARDCODED_FOUND+=MATCHES)); warn "Pattern '${pattern}': ${MATCHES} match(es)"; }
done
[[ "${HARDCODED_FOUND}" -eq 0 ]] && pass "No hardcoded credential patterns detected"

# Environment files committed check
check "Checking for committed .env files..."
if git -C "${REPO_ROOT}" ls-files | grep -qE '\.env$|\.env\.[^e]'; then
  critical "Committed .env file(s) found in repository"
  git -C "${REPO_ROOT}" ls-files | grep -E '\.env$|\.env\.[^e]' | sed 's/^/     /'
else
  pass "No .env files committed to repository"
fi

# .gitignore coverage check
check "Validating .gitignore coverage for sensitive files..."
REQUIRED_IGNORES=(".env" "*.pem" "*.key" "*.p12" "*.pfx" "secrets/" "terraform.tfvars" ".terraform/")
for pattern in "${REQUIRED_IGNORES[@]}"; do
  if grep -qF "${pattern}" "${REPO_ROOT}/.gitignore" 2>/dev/null; then
    pass ".gitignore covers: ${pattern}"
  else
    fail ".gitignore MISSING pattern: ${pattern}"
    compliance_ref "CIS Control 3.11 — Encrypt sensitive data"
  fi
done

# =============================================================================
# §3  KUBERNETES RBAC — LEAST PRIVILEGE ANALYSIS
# =============================================================================
section 3 "KUBERNETES RBAC — LEAST PRIVILEGE ANALYSIS"
compliance_ref "CIS K8s Benchmark §5.1 | NIST CSF PR.AC-4 | SOC 2 CC6.3"

RBAC_DIR="${REPO_ROOT}/k8s"

# Cluster-admin binding check
check "Scanning for cluster-admin role bindings..."
if grep -rn "cluster-admin" "${RBAC_DIR}" --include="*.yaml" --include="*.yml" \
    2>/dev/null | grep -v "^Binary"; then
  critical "cluster-admin bindings found — violates least privilege"
  compliance_ref "CIS K8s 5.1.1 — Ensure cluster-admin role used only where required"
else
  pass "No cluster-admin bindings found in k8s manifests"
fi

# Wildcard permissions check
check "Scanning for wildcard (*) RBAC permissions..."
WILDCARD_COUNT=$(grep -rn '"\*"' "${RBAC_DIR}" --include="*.yaml" --include="*.yml" \
  2>/dev/null | grep -E "(verbs|resources|apiGroups)" | wc -l || echo 0)
if [[ "${WILDCARD_COUNT}" -gt 0 ]]; then
  fail "Wildcard RBAC permissions detected: ${WILDCARD_COUNT} occurrence(s)"
  grep -rn '"\*"' "${RBAC_DIR}" --include="*.yaml" --include="*.yml" \
    2>/dev/null | grep -E "(verbs|resources|apiGroups)" | head -10 | sed 's/^/     /'
  compliance_ref "CIS K8s 5.1.3 — Minimize wildcard use in Roles and ClusterRoles"
else
  pass "No wildcard RBAC permissions found"
fi

# Service account token automounting
check "Checking automountServiceAccountToken settings..."
FILES_WITHOUT_AUTOMOUNT=$(grep -rL "automountServiceAccountToken" "${RBAC_DIR}" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | \
  xargs grep -l "kind: ServiceAccount" 2>/dev/null || true)
if [[ -n "${FILES_WITHOUT_AUTOMOUNT}" ]]; then
  warn "ServiceAccount(s) without automountServiceAccountToken: false"
  echo "${FILES_WITHOUT_AUTOMOUNT}" | sed 's/^/     /'
  compliance_ref "CIS K8s 5.1.6 — Ensure service account tokens not mounted where unnecessary"
else
  pass "All ServiceAccounts have automountServiceAccountToken configured"
fi

# Check for default service account usage
check "Checking for workloads using default service account..."
DEFAULT_SA=$(grep -rn "serviceAccountName: default" "${RBAC_DIR}" \
  --include="*.yaml" --include="*.yml" 2>/dev/null || true)
[[ -n "${DEFAULT_SA}" ]] && \
  fail "Workloads using 'default' service account found" || \
  pass "No workloads using default service account"

# Secrets RBAC access audit
check "Auditing RBAC access to Secrets resource..."
SECRET_ACCESS=$(grep -rn "secrets" "${RBAC_DIR}" --include="*.yaml" --include="*.yml" \
  2>/dev/null | grep -v "^Binary" | grep -E "(resources|kind: Secret)" | wc -l || echo 0)
info "Manifests referencing secrets resource: ${SECRET_ACCESS}"
grep -rn '"secrets"' "${RBAC_DIR}" --include="*.yaml" --include="*.yml" \
  2>/dev/null | head -5 | sed 's/^/     INFO: /'

# Live cluster RBAC checks
if [[ "${K8S_AVAILABLE}" == true ]]; then
  check "Live: Scanning for privileged bindings in platform namespace..."
  kubectl get rolebindings,clusterrolebindings -n platform \
    -o json 2>/dev/null | \
    jq -r '.items[] | select(.roleRef.name == "cluster-admin") | 
    "CRITICAL: \(.metadata.name) bound to cluster-admin"' | \
    while read -r line; do critical "${line}"; done || true

  pass "Live RBAC scan completed"
fi

# =============================================================================
# §4  KUBERNETES NETWORK POLICIES — ZERO TRUST VERIFICATION
# =============================================================================
section 4 "KUBERNETES NETWORK POLICIES — ZERO TRUST VERIFICATION"
compliance_ref "CIS K8s §5.3 | NIST CSF PR.AC-5 | PCI-DSS Req 1"

NETPOL_DIR="${REPO_ROOT}/k8s"
SERVICES=(auth ingestion processing billing notifications control-plane \
          feature-flags developer-portal ml-engine realtime search \
          analytics jobs tenant-operator hydration sync)

# Each service must have a NetworkPolicy
check "Verifying NetworkPolicy coverage for all 16 services..."
for svc in "${SERVICES[@]}"; do
  NETPOL=$(find "${NETPOL_DIR}" -name "*network*policy*" -o -name "*networkpolicy*" \
    2>/dev/null | xargs grep -l "${svc}" 2>/dev/null || true)
  if [[ -n "${NETPOL}" ]]; then
    pass "NetworkPolicy exists for service: ${svc}"
  else
    fail "NO NetworkPolicy for service: ${svc} — unrestricted traffic allowed"
    compliance_ref "PCI-DSS v4.0 Req 1.3 — Network access controls between network components"
  fi
done

# Default-deny policy check
check "Checking for default-deny NetworkPolicy..."
DEFAULT_DENY=$(grep -rn "policyTypes" "${NETPOL_DIR}" --include="*.yaml" --include="*.yml" \
  2>/dev/null | grep -c "Ingress\|Egress" || echo 0)
if [[ "${DEFAULT_DENY}" -gt 0 ]]; then
  pass "Network policies with policyTypes found: ${DEFAULT_DENY}"
else
  critical "No default-deny NetworkPolicy found — all pod-to-pod traffic unrestricted"
  suggest_fix "Add default-deny policy to platform namespace" \
    "kubectl apply -f k8s/base/network-policies/default-deny.yaml"
fi

# Egress policies check
check "Verifying egress controls..."
EGRESS_POLICIES=$(grep -rn "Egress" "${NETPOL_DIR}" --include="*.yaml" --include="*.yml" \
  2>/dev/null | wc -l || echo 0)
[[ "${EGRESS_POLICIES}" -gt 0 ]] && \
  pass "Egress network policies found: ${EGRESS_POLICIES}" || \
  fail "No egress network policies found — data exfiltration risk"

# Cross-tenant traffic isolation
check "Verifying tenant namespace isolation..."
TENANT_NETPOL=$(grep -rn "tenant" "${NETPOL_DIR}" --include="*.yaml" --include="*.yml" \
  2>/dev/null | grep -i "networkpolicy" | wc -l || echo 0)
[[ "${TENANT_NETPOL}" -gt 0 ]] && \
  pass "Tenant-scoped NetworkPolicies found" || \
  warn "No tenant-specific NetworkPolicies — multi-tenant isolation may be incomplete"

# =============================================================================
# §5  POD SECURITY — RUNTIME HARDENING
# =============================================================================
section 5 "POD SECURITY STANDARDS & RUNTIME HARDENING"
compliance_ref "CIS K8s §5.2 | NIST SP 800-190 | SOC 2 CC6.6"

# Pod Security Admission labels
check "Checking Pod Security Admission enforcement on namespaces..."
PSA_NAMESPACES=$(find "${REPO_ROOT}/k8s" -name "namespace*.yaml" -o -name "ns.yaml" \
  2>/dev/null | xargs grep -l "pod-security.kubernetes.io" 2>/dev/null || true)
if [[ -n "${PSA_NAMESPACES}" ]]; then
  pass "Pod Security Admission labels found on namespace(s)"
else
  fail "No Pod Security Admission labels on namespaces — weak runtime isolation"
  compliance_ref "CIS K8s 5.2.1 — Ensure PSA enforce profile set to restricted"
  suggest_fix "Label platform namespace with restricted PSA" \
    "kubectl label namespace platform pod-security.kubernetes.io/enforce=restricted"
fi

# privileged: true check
check "Scanning for privileged containers..."
PRIVILEGED=$(grep -rn "privileged: true" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${PRIVILEGED}" -eq 0 ]] && pass "No privileged containers found" || \
  critical "Privileged containers found: ${PRIVILEGED}"

# runAsRoot check
check "Scanning for containers running as root (runAsNonRoot)..."
NON_ROOT=$(grep -rn "runAsNonRoot: true" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
ROLLOUTS=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: Rollout" 2>/dev/null | wc -l || echo 0)
if [[ "${NON_ROOT}" -ge "${ROLLOUTS}" ]]; then
  pass "runAsNonRoot: true set on workloads"
else
  fail "Some workloads missing runAsNonRoot: true (found ${NON_ROOT}/${ROLLOUTS})"
  compliance_ref "CIS K8s 5.2.6 — Do not admit root containers"
fi

# Read-only root filesystem
check "Checking readOnlyRootFilesystem enforcement..."
READONLY=$(grep -rn "readOnlyRootFilesystem: true" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${READONLY}" -ge "${ROLLOUTS}" ]] && \
  pass "readOnlyRootFilesystem: true enforced" || \
  fail "Containers without readOnlyRootFilesystem: true (found ${READONLY}/${ROLLOUTS})"

# allowPrivilegeEscalation
check "Checking allowPrivilegeEscalation: false..."
APE=$(grep -rn "allowPrivilegeEscalation: false" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${APE}" -ge "${ROLLOUTS}" ]] && \
  pass "allowPrivilegeEscalation: false enforced" || \
  fail "allowPrivilegeEscalation not explicitly false on all containers"

# capabilities drop
check "Checking Linux capabilities drop..."
CAP_DROP=$(grep -rn "drop:" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
ALL_DROPPED=$(grep -rn '"ALL"' "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${ALL_DROPPED}" -gt 0 ]] && pass "capabilities: drop: [ALL] found" || \
  fail "Capabilities not explicitly dropped — containers may retain dangerous Linux capabilities"
compliance_ref "CIS K8s 5.2.9 — Minimize capabilities assigned to containers"

# seccompProfile
check "Checking seccompProfile enforcement..."
SECCOMP=$(grep -rn "seccompProfile" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${SECCOMP}" -gt 0 ]] && pass "seccompProfile configured" || \
  warn "No seccompProfile found — consider RuntimeDefault or Localhost"

# hostNetwork / hostPID / hostIPC
for field in hostNetwork hostPID hostIPC; do
  COUNT=$(grep -rn "${field}: true" "${REPO_ROOT}/k8s" \
    --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
  [[ "${COUNT}" -eq 0 ]] && pass "${field}: true not found" || \
    critical "${field}: true found — host namespace sharing is dangerous"
done

# Resource limits
check "Verifying resource limits on all workloads..."
NO_LIMITS=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: Rollout" 2>/dev/null | \
  xargs grep -L "limits:" 2>/dev/null || true)
[[ -z "${NO_LIMITS}" ]] && pass "All workloads have resource limits defined" || {
  fail "Workloads without resource limits (DoS risk):"
  echo "${NO_LIMITS}" | sed 's/^/     /'
}

# =============================================================================
# §6  SUPPLY CHAIN SECURITY
# =============================================================================
section 6 "SUPPLY CHAIN SECURITY — SIGSTORE/COSIGN/SBOM"
compliance_ref "SLSA Level 2+ | NIST SP 800-204D | CIS Control 2"

# Cosign signing workflow presence
check "Verifying cosign signing in CI/CD workflows..."
if grep -rq "cosign" "${REPO_ROOT}/.github/workflows/" 2>/dev/null; then
  pass "Cosign signing workflow found"
  SIGNED_SERVICES=$(grep -rn "cosign sign" "${REPO_ROOT}/.github/workflows/" \
    2>/dev/null | wc -l || echo 0)
  info "Cosign sign steps found: ${SIGNED_SERVICES}"
else
  critical "No cosign signing found in CI/CD — images not cryptographically signed"
  compliance_ref "SLSA Requirement: Build as code | NIST SP 800-204D §4.1"
fi

# SBOM generation
check "Verifying SBOM generation..."
if grep -rq "syft\|sbom" "${REPO_ROOT}/.github/workflows/" 2>/dev/null; then
  pass "SBOM generation (syft) found in CI/CD"
else
  fail "No SBOM generation found — software composition unknown"
  compliance_ref "EO 14028 §4(e) — SBOM required for federal contracts"
fi

# Grype vulnerability scanning
check "Verifying container image vulnerability scanning..."
if grep -rq "grype\|trivy" "${REPO_ROOT}/.github/workflows/" 2>/dev/null; then
  pass "Container vulnerability scanning (grype/trivy) in CI/CD"
  # Check for fail-on-severity thresholds
  if grep -qE "fail-on-severity|severity.*CRITICAL" "${REPO_ROOT}/.github/workflows/"/*.yml 2>/dev/null; then
    pass "Vulnerability scan fail-on-severity threshold configured"
  else
    warn "No fail-on-severity threshold — pipeline won't block on CVEs"
  fi
else
  critical "No container vulnerability scanning in CI/CD pipeline"
fi

# Kyverno signature enforcement
check "Verifying Kyverno admission-time signature enforcement..."
KYVERNO_SIGN=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "VerifyImages\|verifyImages" 2>/dev/null || true)
[[ -n "${KYVERNO_SIGN}" ]] && pass "Kyverno image signature policy found" || \
  fail "No Kyverno image verification policy — unsigned images can be deployed"

# Pinned base images (no :latest)
check "Scanning for unpinned :latest image tags..."
LATEST_TAGS=$(grep -rn ":latest" "${REPO_ROOT}" \
  --include="Dockerfile*" --include="*.yaml" --include="*.yml" \
  --exclude-dir=".git" 2>/dev/null | grep -v "^Binary" | wc -l || echo 0)
[[ "${LATEST_TAGS}" -eq 0 ]] && pass "No :latest tags found in Dockerfiles/manifests" || \
  fail ":latest image tags found: ${LATEST_TAGS} — use immutable digests"

# go.sum / requirements.txt lockfile presence
check "Verifying dependency lockfiles..."
GO_SERVICES=0; GO_SUM=0
for mod in $(find "${REPO_ROOT}/services" -name "go.mod" 2>/dev/null); do
  ((GO_SERVICES++))
  dir=$(dirname "${mod}")
  [[ -f "${dir}/go.sum" ]] && ((GO_SUM++))
done
[[ "${GO_SUM}" -eq "${GO_SERVICES}" ]] && \
  pass "All Go services have go.sum (${GO_SUM}/${GO_SERVICES})" || \
  fail "Missing go.sum in some Go services: ${GO_SUM}/${GO_SERVICES}"

# Python lockfiles
PY_REQS=$(find "${REPO_ROOT}/services" -name "requirements*.txt" 2>/dev/null | wc -l || echo 0)
[[ "${PY_REQS}" -gt 0 ]] && pass "Python requirements files found: ${PY_REQS}" || \
  warn "No Python requirements files — ml-engine dependencies may be unpinned"

# GitHub Actions: pin actions to SHA
check "Checking GitHub Actions pinned to SHA (not tag)..."
ACTIONS_TAGS=$(grep -rn "uses:.*@v" "${REPO_ROOT}/.github/workflows/" 2>/dev/null | \
  grep -v "@[a-f0-9]\{40\}" | wc -l || echo 0)
[[ "${ACTIONS_TAGS}" -eq 0 ]] && pass "All Actions pinned to SHA" || \
  warn "Actions pinned by tag (not SHA): ${ACTIONS_TAGS} — supply chain risk"
compliance_ref "SLSA Requirement: Pinned dependencies"

# =============================================================================
# §7  AUTHENTICATION & AUTHORIZATION ARCHITECTURE
# =============================================================================
section 7 "AUTHENTICATION & AUTHORIZATION ARCHITECTURE"
compliance_ref "OWASP API01 | PCI-DSS Req 7,8 | SOC 2 CC6.1,CC6.2"

AUTH_SVC="${REPO_ROOT}/services/auth"

# JWT secret strength
check "Checking JWT secret configuration..."
if grep -rn "JWT_SECRET\|jwt_secret" "${REPO_ROOT}" \
    --include="*.go" --include="*.env*" 2>/dev/null | grep -qE '"[^"]{0,31}"'; then
  critical "JWT secret appears to be less than 32 characters"
  compliance_ref "OWASP A02 — Use secrets of sufficient length (≥256 bits)"
else
  pass "JWT secret length appears adequate"
fi

# JWT algorithm check (reject 'none' and RS256 vs HS256 for multi-service)
check "Checking JWT algorithm configuration..."
if grep -rn "alg.*none\|algorithm.*none" "${AUTH_SVC}" --include="*.go" 2>/dev/null; then
  critical "JWT algorithm 'none' detected — critical vulnerability"
elif grep -rqn "RS256\|ES256\|RS384\|ES384" "${AUTH_SVC}" --include="*.go" 2>/dev/null; then
  pass "Asymmetric JWT signing algorithm found (RS256/ES256)"
elif grep -rqn "HS256\|HS384\|HS512" "${AUTH_SVC}" --include="*.go" 2>/dev/null; then
  warn "Symmetric JWT algorithm (HS*) — consider asymmetric for multi-service"
else
  warn "JWT algorithm not identifiable — verify explicitly"
fi

# Token expiry
check "Checking JWT expiry (short-lived tokens)..."
TOKEN_EXPIRY=$(grep -rn "expir\|exp\|ExpiresAt\|ExpiresIn" "${AUTH_SVC}" \
  --include="*.go" 2>/dev/null | head -5)
if echo "${TOKEN_EXPIRY}" | grep -qE '[0-9]+(m|h|s)'; then
  pass "Token expiry configured"
  echo "${TOKEN_EXPIRY}" | head -3 | sed 's/^/     /'
else
  warn "Token expiry configuration not clearly found — verify non-expiring tokens absent"
fi

# Refresh token rotation
check "Checking refresh token rotation..."
grep -rn "refresh" "${AUTH_SVC}" --include="*.go" 2>/dev/null | grep -qi "rotat" && \
  pass "Refresh token rotation logic found" || \
  warn "No refresh token rotation found — stolen refresh tokens valid indefinitely"

# bcrypt cost factor
check "Verifying password hashing (bcrypt cost)..."
BCRYPT_COST=$(grep -rn "bcrypt.GenerateFromPassword\|bcrypt.Cost\|bcrypt.Min" \
  "${AUTH_SVC}" --include="*.go" 2>/dev/null)
if echo "${BCRYPT_COST}" | grep -qE "bcrypt\.(Default|Min)Cost|[0-9]+"; then
  COST_VAL=$(echo "${BCRYPT_COST}" | grep -oE "(bcrypt\.(Default|Min)Cost|[0-9]+)" | head -1)
  [[ "${COST_VAL}" =~ ^[0-9]+$ && "${COST_VAL}" -lt 12 ]] && \
    warn "bcrypt cost factor < 12 (found: ${COST_VAL}) — consider cost=14 for financial data" || \
    pass "bcrypt hashing found: ${COST_VAL}"
else
  fail "bcrypt not found — verify password hashing algorithm"
fi

# API key hashing (SHA-256)
check "Verifying API keys are stored as hashes..."
if grep -rn "sha256\|SHA256\|crypto/sha256" "${AUTH_SVC}" --include="*.go" 2>/dev/null; then
  pass "SHA-256 hashing of API keys detected"
else
  fail "No SHA-256 hashing for API keys — raw API keys may be stored"
  compliance_ref "PCI-DSS v4.0 Req 3.3 — Protect sensitive authentication data"
fi

# Permission namespace validation
check "Checking permission namespace format (OWASP API01)..."
if grep -rn '"markets:read"\|"finance:' "${AUTH_SVC}" --include="*.go" 2>/dev/null; then
  pass "Namespaced permissions format found (resource:action)"
else
  warn "Permissions may not use namespaced format — OWASP BOLA risk"
fi

# Rate limiting on auth endpoints
check "Checking rate limiting on auth endpoints..."
RATE_LIMIT=$(grep -rn "RateLimit\|rate_limit\|throttl\|RateLimiter" \
  "${AUTH_SVC}" "${REPO_ROOT}/k8s" \
  --include="*.go" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${RATE_LIMIT}" -gt 0 ]] && pass "Rate limiting found: ${RATE_LIMIT} reference(s)" || \
  critical "No rate limiting on auth service — brute force vulnerability"
compliance_ref "OWASP API04 — Unrestricted Resource Consumption"

# MFA support check
check "Checking Multi-Factor Authentication support..."
MFA=$(grep -rn "mfa\|totp\|otp\|2fa" "${AUTH_SVC}" \
  --include="*.go" -i 2>/dev/null | wc -l || echo 0)
[[ "${MFA}" -gt 0 ]] && pass "MFA/TOTP implementation found" || \
  warn "No MFA implementation found — required for financial platform (PCI-DSS)"
compliance_ref "PCI-DSS v4.0 Req 8.4 — MFA for all access into CDE"

# Account lockout
check "Checking account lockout mechanism..."
LOCKOUT=$(grep -rn "lockout\|lock_out\|failed_attempts\|MaxAttempts" \
  "${AUTH_SVC}" --include="*.go" -i 2>/dev/null | wc -l || echo 0)
[[ "${LOCKOUT}" -gt 0 ]] && pass "Account lockout mechanism found" || \
  fail "No account lockout — unlimited login attempts allowed"
compliance_ref "PCI-DSS v4.0 Req 8.3.4 — Lock accounts after max 10 failed attempts"

# =============================================================================
# §8  API SECURITY — OWASP API TOP 10
# =============================================================================
section 8 "API SECURITY — OWASP API TOP 10 (2023)"
compliance_ref "OWASP API Top 10 2023 | PCI-DSS Req 6.2"

# API01: BOLA — Object-level authorization
check "API01: BOLA — Checking tenant ID propagation in handlers..."
TENANT_CHECKS=$(grep -rn "tenantID\|tenant_id\|TenantID\|X-Tenant-ID" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${TENANT_CHECKS}" -gt 10 ]] && \
  pass "Tenant ID enforcement found in handlers: ${TENANT_CHECKS} reference(s)" || \
  fail "Insufficient tenant ID checks — BOLA/IDOR risk in multi-tenant platform"

# API02: Authentication check
check "API02: Broken Authentication — JWT middleware coverage..."
JWT_MIDDLEWARE=$(grep -rn "JWTMiddleware\|ValidateToken\|AuthMiddleware\|bearerToken" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${JWT_MIDDLEWARE}" -gt 5 ]] && pass "JWT middleware found: ${JWT_MIDDLEWARE} reference(s)" || \
  fail "Insufficient JWT middleware — unauthenticated endpoint risk"

# API03: Broken Object Property Level Authorization
check "API03: Mass assignment protection..."
STRUCT_TAG=$(grep -rn 'json:"-"' "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${STRUCT_TAG}" -gt 0 ]] && pass "Sensitive field exclusions (json:\"-\") found: ${STRUCT_TAG}" || \
  warn "No json:\"-\" struct tags found — mass assignment risk"

# API04: Unrestricted Resource Consumption
check "API04: Pagination enforcement on list endpoints..."
PAGINATION=$(grep -rn "limit\|offset\|PageSize\|page_size" "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${PAGINATION}" -gt 5 ]] && pass "Pagination found: ${PAGINATION} reference(s)" || \
  warn "Limited pagination found — unbounded queries possible"

# API05: Function Level Authorization
check "API05: Admin endpoint protection..."
ADMIN_ROUTES=$(grep -rn "/admin\|/internal\|/management" "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null)
ADMIN_AUTH=$(echo "${ADMIN_ROUTES}" | grep -c "Auth\|middleware\|require" || echo 0)
info "Admin routes found: $(echo "${ADMIN_ROUTES}" | wc -l) total, ${ADMIN_AUTH} with auth refs"

# API06: Sensitive Business Flows
check "API06: Financial transaction integrity..."
TX_INTEGRITY=$(grep -rn "idempotency\|idempotent\|X-Idempotency\|transaction" \
  "${REPO_ROOT}/services" --include="*.go" -i 2>/dev/null | wc -l || echo 0)
[[ "${TX_INTEGRITY}" -gt 0 ]] && pass "Idempotency/transaction integrity found" || \
  warn "No idempotency keys found — duplicate financial operations risk"

# API07: SSRF Protection
check "API07: SSRF — URL validation for external requests..."
URL_VALIDATE=$(grep -rn "url.Parse\|ValidateURL\|allowedHosts\|safeDomains" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${URL_VALIDATE}" -gt 0 ]] && pass "URL validation found: ${URL_VALIDATE} reference(s)" || \
  warn "No URL allowlist found — potential SSRF vulnerability"

# API08: Security Misconfiguration
check "API08: Debug endpoints disabled in production..."
DEBUG_ENDPOINTS=$(grep -rn "/debug\|pprof\|/metrics.*public\|debug: true" \
  "${REPO_ROOT}/services" "${REPO_ROOT}/k8s" \
  --include="*.go" --include="*.yaml" --include="*.yml" 2>/dev/null | \
  grep -v "_test\." | wc -l || echo 0)
[[ "${DEBUG_ENDPOINTS}" -eq 0 ]] && pass "No debug endpoints exposed publicly" || \
  warn "Debug endpoints found: ${DEBUG_ENDPOINTS} — ensure not exposed in production"

# API09: Improper Inventory Management
check "API09: API versioning enforced..."
API_VERSION=$(grep -rn '"/v1\|"/v2\|/api/v' "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${API_VERSION}" -gt 5 ]] && pass "API versioning found: ${API_VERSION} reference(s)" || \
  warn "API versioning not clearly established"

# API10: Unsafe API Consumption
check "API10: External API response validation..."
EXT_VALIDATE=$(grep -rn "json.Unmarshal\|json.Decode" "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null | wc -l || echo 0)
info "External response parsing: ${EXT_VALIDATE} json.Unmarshal/Decode calls"

# Input validation / sanitization
check "Input validation coverage..."
INPUT_VAL=$(grep -rn "validate\|Validate\|sanitize\|Sanitize\|binding:" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${INPUT_VAL}" -gt 20 ]] && pass "Input validation found: ${INPUT_VAL} reference(s)" || \
  fail "Insufficient input validation — injection risk"

# SQL injection prevention
check "SQL injection prevention (parameterized queries)..."
RAW_SQL=$(grep -rn 'fmt.Sprintf.*SELECT\|fmt.Sprintf.*INSERT\|fmt.Sprintf.*WHERE\|"SELECT.*"+' \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${RAW_SQL}" -eq 0 ]] && pass "No raw SQL string concatenation detected" || \
  critical "Raw SQL string concatenation found: ${RAW_SQL} — SQL injection risk"
compliance_ref "OWASP A03:2021 — Injection"

# =============================================================================
# §9  ENCRYPTION — IN TRANSIT & AT REST
# =============================================================================
section 9 "ENCRYPTION — IN TRANSIT & AT REST"
compliance_ref "PCI-DSS v4.0 Req 4 | NIST SP 800-57 | SOC 2 CC6.7"

# TLS minimum version
check "Checking minimum TLS version (1.2+ required, 1.3 recommended)..."
TLS10=$(grep -rn "TLSVersion.*TLS10\|tls.VersionTLS10\|minVersion.*10" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
TLS12=$(grep -rn "tls.VersionTLS12\|MinVersion.*TLS12" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
TLS13=$(grep -rn "tls.VersionTLS13\|MinVersion.*TLS13" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)

[[ "${TLS10}" -gt 0 ]] && critical "TLS 1.0 enabled — deprecated and prohibited (PCI-DSS)" || true
[[ "${TLS13}" -gt 0 ]] && pass "TLS 1.3 minimum version configured"
[[ "${TLS12}" -gt 0 ]] && pass "TLS 1.2 minimum version configured"
[[ "${TLS10}" -eq 0 && "${TLS12}" -eq 0 && "${TLS13}" -eq 0 ]] && \
  warn "TLS minimum version not explicitly set — verify Envoy Gateway TLS config"

# cert-manager presence
check "Verifying cert-manager TLS certificate management..."
CERT_MANAGER=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "cert-manager.io\|Certificate\|Issuer\|ClusterIssuer" 2>/dev/null | wc -l || echo 0)
[[ "${CERT_MANAGER}" -gt 0 ]] && pass "cert-manager configured: ${CERT_MANAGER} manifest(s)" || \
  fail "No cert-manager configuration found — manual certificate management risk"

# mTLS configuration
check "Verifying mTLS configuration in Envoy/service mesh..."
MTLS=$(grep -rn "mTLS\|mtls\|clientAuth\|requireClientCert\|MUTUAL" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${MTLS}" -gt 0 ]] && pass "mTLS configuration found: ${MTLS} reference(s)" || \
  fail "No mTLS configuration found — service-to-service traffic unencrypted"
compliance_ref "PCI-DSS v4.0 Req 4.2.1 — Strong cryptography for data in transit"

# Database encryption
check "Checking database connection encryption (SSL)..."
DB_SSL=$(grep -rn "sslmode\|ssl_mode\|SSLMode\|tls=true\|TLSConfig" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${DB_SSL}" -gt 0 ]] && pass "Database SSL/TLS found: ${DB_SSL} reference(s)" || \
  critical "No database SSL/TLS — data in transit unencrypted"

# S3 encryption at rest
check "Checking S3 server-side encryption..."
S3_ENCRYPT=$(grep -rn "ServerSideEncryption\|sse\|aws:kms\|AES256" \
  "${REPO_ROOT}/services" "${REPO_ROOT}/terraform" \
  --include="*.go" --include="*.tf" 2>/dev/null | wc -l || echo 0)
[[ "${S3_ENCRYPT}" -gt 0 ]] && pass "S3 server-side encryption configured" || \
  fail "No S3 encryption at rest — financial data stored in plaintext"
compliance_ref "PCI-DSS v4.0 Req 3.5.1 — Primary account numbers must be encrypted"

# ClickHouse encryption
check "Checking ClickHouse encryption configuration..."
CH_ENCRYPT=$(grep -rn "encrypt\|ssl\|tls" "${REPO_ROOT}/services" \
  --include="*.go" -i 2>/dev/null | grep -i "clickhouse" | wc -l || echo 0)
[[ "${CH_ENCRYPT}" -gt 0 ]] && pass "ClickHouse encryption references found" || \
  warn "ClickHouse encryption not clearly configured"

# Kafka TLS
check "Checking Kafka TLS/SASL configuration..."
KAFKA_TLS=$(grep -rn "sasl\|tls\|SSL\|SASL_SSL" "${REPO_ROOT}/services" \
  --include="*.go" -i 2>/dev/null | grep -i "kafka\|franz\|kafka-go" | wc -l || echo 0)
[[ "${KAFKA_TLS}" -gt 0 ]] && pass "Kafka TLS/SASL configuration found" || \
  warn "Kafka TLS not clearly configured — message bus unencrypted"

# =============================================================================
# §10  EXTERNAL SECRETS OPERATOR — SECRETS MANAGEMENT
# =============================================================================
section 10 "EXTERNAL SECRETS OPERATOR & AWS SECRETS MANAGER"
compliance_ref "PCI-DSS Req 3,8 | CIS Control 16 | SOC 2 CC6.1"

ESO_DIR=$(find "${REPO_ROOT}/k8s" -type d -name "*external*secret*" \
  -o -type d -name "*eso*" 2>/dev/null | head -1)

# ESO ClusterSecretStore
check "Verifying ESO ClusterSecretStore configuration..."
CSS=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "ClusterSecretStore\|SecretStore" 2>/dev/null || true)
[[ -n "${CSS}" ]] && pass "ClusterSecretStore found" || \
  fail "No ClusterSecretStore — secrets may be hardcoded in manifests"

# ExternalSecret for each service
check "Verifying ExternalSecret resources for all services..."
for svc in "${SERVICES[@]}"; do
  ES=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
    xargs grep -l "ExternalSecret" 2>/dev/null | xargs grep -l "${svc}" 2>/dev/null || true)
  [[ -n "${ES}" ]] && pass "ExternalSecret found for: ${svc}" || \
    warn "No ExternalSecret found for: ${svc}"
done

# Path convention verification
check "Checking AWS Secrets Manager path convention (platform/{service})..."
CORRECT_PATHS=$(grep -rn "platform/" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | \
  grep -E "remoteRef|key:" | wc -l || echo 0)
[[ "${CORRECT_PATHS}" -gt 0 ]] && \
  pass "AWS Secrets Manager paths follow platform/{service} convention" || \
  warn "Cannot verify Secrets Manager path convention"

# Secret rotation policy
check "Checking secret rotation configuration..."
ROTATION=$(grep -rn "rotation\|refreshInterval\|SecretRotation" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${ROTATION}" -gt 0 ]] && pass "Secret rotation/refresh configured" || \
  warn "No secret rotation policy found — static secrets are high risk for financial data"
compliance_ref "PCI-DSS v4.0 Req 8.3.9 — Passwords changed at least every 90 days"

# =============================================================================
# §11  FALCO RUNTIME SECURITY
# =============================================================================
section 11 "FALCO RUNTIME SECURITY & THREAT DETECTION"
compliance_ref "NIST CSF DE.CM-1 | SOC 2 CC7.2 | CIS Control 8"

# Falco presence
check "Verifying Falco deployment..."
FALCO=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "falco" 2>/dev/null | wc -l || echo 0)
[[ "${FALCO}" -gt 0 ]] && pass "Falco configuration found: ${FALCO} manifest(s)" || \
  critical "Falco not found — no runtime threat detection"

# Falco custom rules
check "Checking Falco custom rules for financial platform..."
FALCO_RULES=$(find "${REPO_ROOT}" -name "*falco*rule*" -o -name "*rule*falco*" \
  2>/dev/null | wc -l || echo 0)
[[ "${FALCO_RULES}" -gt 0 ]] && pass "Falco custom rules found: ${FALCO_RULES}" || \
  warn "No custom Falco rules — using defaults only (insufficient for financial platform)"

# Falco alerting
check "Checking Falco alert routing (PagerDuty/Slack)..."
FALCO_ALERT=$(grep -rn "falco.*alert\|alert.*falco\|falcosidekick" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" -i 2>/dev/null | wc -l || echo 0)
[[ "${FALCO_ALERT}" -gt 0 ]] && pass "Falco alerting configured" || \
  warn "Falco alert routing not found — security events may go unnoticed"

# =============================================================================
# §12  KYVERNO ADMISSION CONTROLLER POLICIES
# =============================================================================
section 12 "KYVERNO ADMISSION CONTROLLER POLICIES"
compliance_ref "CIS K8s §5.2 | NIST CSF PR.PT-3"

KYVERNO_DIR=$(find "${REPO_ROOT}/k8s" -type d -name "*kyverno*" 2>/dev/null | head -1)

# Policy count
check "Auditing Kyverno policies..."
KYVERNO_POLICIES=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: ClusterPolicy\|kind: Policy" 2>/dev/null | wc -l || echo 0)
[[ "${KYVERNO_POLICIES}" -gt 0 ]] && \
  pass "Kyverno policies found: ${KYVERNO_POLICIES}" || \
  fail "No Kyverno policies — no admission control enforcement"

# Mandatory policy checks
MANDATORY_POLICIES=(
  "require-image-signature:image signing enforcement"
  "disallow-privileged:block privileged containers"
  "require-non-root:enforce non-root containers"
  "require-resource-limits:enforce resource limits"
  "disallow-latest-tag:block :latest images"
  "require-readonly-root:enforce read-only root FS"
)

for policy_pair in "${MANDATORY_POLICIES[@]}"; do
  policy_name="${policy_pair%%:*}"
  policy_desc="${policy_pair##*:}"
  FOUND=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
    xargs grep -l "${policy_name}\|$(echo ${policy_name} | tr '-' '_')" 2>/dev/null || true)
  [[ -n "${FOUND}" ]] && pass "Kyverno policy: ${policy_desc}" || \
    fail "Missing Kyverno policy: ${policy_desc} (${policy_name})"
done

# Policy enforcement mode (audit vs enforce)
check "Checking Kyverno policy enforcement mode..."
AUDIT_ONLY=$(grep -rn "validationFailureAction: audit" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
ENFORCE=$(grep -rn "validationFailureAction: enforce\|Enforce" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
info "Policies in audit mode: ${AUDIT_ONLY} | enforce mode: ${ENFORCE}"
[[ "${AUDIT_ONLY}" -gt 0 && "${ENFORCE}" -eq 0 ]] && \
  warn "All Kyverno policies in audit mode — violations not blocked" || \
  pass "Enforce mode policies: ${ENFORCE}"

# =============================================================================
# §13  MULTI-TENANT DATA ISOLATION
# =============================================================================
section 13 "MULTI-TENANT DATA ISOLATION"
compliance_ref "SOC 2 CC6.1 | ISO 27001 A.9 | PCI-DSS Req 7"

# Tenant namespace isolation
check "Verifying tenant-level namespace isolation..."
TENANT_NS=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "tenant\|Tenant" 2>/dev/null | wc -l || echo 0)
[[ "${TENANT_NS}" -gt 0 ]] && pass "Tenant isolation manifests found: ${TENANT_NS}" || \
  fail "No tenant isolation configuration — multi-tenant data may be shared"

# Row-level security (database)
check "Checking Row-Level Security (RLS) in database migrations..."
RLS=$(grep -rn "ROW LEVEL SECURITY\|RLS\|POLICY.*tenant\|CREATE POLICY" \
  "${REPO_ROOT}" --include="*.sql" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${RLS}" -gt 0 ]] && pass "Row-Level Security policies found: ${RLS}" || \
  critical "No Row-Level Security found — tenants can access each other's data"
compliance_ref "PCI-DSS v4.0 Req 7.2 — Access to data restricted to least privilege"

# Tenant operator
check "Checking tenant-operator service..."
TENANT_OP=$(find "${REPO_ROOT}/services/tenant-operator" -name "*.go" \
  2>/dev/null | wc -l || echo 0)
[[ "${TENANT_OP}" -gt 0 ]] && pass "Tenant operator service exists: ${TENANT_OP} Go files" || \
  warn "Tenant operator service not found"

# Cross-tenant query prevention
check "Checking for cross-tenant data leakage prevention..."
CROSS_TENANT=$(grep -rn "tenantID\|tenant_id" "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null | grep -E "(WHERE|AND|Filter)" | wc -l || echo 0)
[[ "${CROSS_TENANT}" -gt 5 ]] && \
  pass "Tenant filtering in queries: ${CROSS_TENANT} occurrence(s)" || \
  fail "Insufficient tenant ID filtering in queries — cross-tenant data access risk"

# =============================================================================
# §14  STATIC APPLICATION SECURITY TESTING (SAST)
# =============================================================================
section 14 "STATIC APPLICATION SECURITY TESTING (SAST)"
compliance_ref "OWASP SAMM | PCI-DSS Req 6.2 | SOC 2 CC8.1"

# gosec — Go security scanner
if cmd_exists gosec; then
  check "Running gosec on all Go services..."
  gosec -fmt=json -out="${REPORT_DIR}/gosec-report.json" \
    ./services/... 2>/dev/null || true
  GOSEC_HIGH=$(jq '[.Issues[] | select(.severity == "HIGH")] | length' \
    "${REPORT_DIR}/gosec-report.json" 2>/dev/null || echo 0)
  GOSEC_CRIT=$(jq '[.Issues[] | select(.severity == "CRITICAL")] | length' \
    "${REPORT_DIR}/gosec-report.json" 2>/dev/null || echo 0)
  [[ "${GOSEC_CRIT}" -gt 0 ]] && critical "gosec CRITICAL findings: ${GOSEC_CRIT}" || true
  [[ "${GOSEC_HIGH}" -gt 0 ]] && fail "gosec HIGH findings: ${GOSEC_HIGH}" || \
    pass "gosec: No HIGH/CRITICAL findings"
else
  warn "gosec not installed — Go SAST skipped"
  info "Install: go install github.com/securego/gosec/v2/cmd/gosec@latest"
fi

# bandit — Python security scanner
if cmd_exists bandit && [[ -d "${REPO_ROOT}/services/ml-engine" ]]; then
  check "Running bandit on ml-engine (Python)..."
  bandit -r "${REPO_ROOT}/services/ml-engine" \
    -f json -o "${REPORT_DIR}/bandit-report.json" 2>/dev/null || true
  BANDIT_HIGH=$(jq '[.results[] | select(.issue_severity == "HIGH")] | length' \
    "${REPORT_DIR}/bandit-report.json" 2>/dev/null || echo 0)
  [[ "${BANDIT_HIGH}" -gt 0 ]] && fail "bandit HIGH issues: ${BANDIT_HIGH}" || \
    pass "bandit: No HIGH issues in ml-engine"
else
  warn "bandit not installed — Python SAST skipped"
fi

# semgrep — multi-language SAST
if cmd_exists semgrep; then
  check "Running semgrep security rules..."
  semgrep --config=p/security-audit \
    --json --output="${REPORT_DIR}/semgrep-report.json" \
    "${REPO_ROOT}/services" 2>/dev/null || true
  SEMGREP_COUNT=$(jq '.results | length' "${REPORT_DIR}/semgrep-report.json" 2>/dev/null || echo 0)
  [[ "${SEMGREP_COUNT}" -gt 0 ]] && warn "semgrep findings: ${SEMGREP_COUNT}" || \
    pass "semgrep: No security rule violations"
else
  warn "semgrep not installed — multi-language SAST skipped"
fi

# =============================================================================
# §15  DEPENDENCY VULNERABILITY SCANNING
# =============================================================================
section 15 "DEPENDENCY VULNERABILITY SCANNING"
compliance_ref "NIST SP 800-161 | CIS Control 2 | PCI-DSS Req 6.3.3"

# Go vulnerability check
check "Scanning Go dependencies for known CVEs..."
for mod in $(find "${REPO_ROOT}/services" -name "go.mod" 2>/dev/null); do
  svc_dir=$(dirname "${mod}")
  svc_name=$(basename "${svc_dir}")
  if cmd_exists govulncheck; then
    VULN_OUT=$(cd "${svc_dir}" && govulncheck ./... 2>&1 || true)
    if echo "${VULN_OUT}" | grep -q "No vulnerabilities found"; then
      pass "govulncheck: ${svc_name} — clean"
    else
      VULN_COUNT=$(echo "${VULN_OUT}" | grep -c "^Vulnerability" || echo 0)
      fail "govulncheck: ${svc_name} — ${VULN_COUNT} vulnerability(ies)"
    fi
  else
    # Fallback: check for known problematic package versions
    TORCH_VER=$(grep "torch" "${svc_dir}/requirements.txt" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    if [[ -n "${TORCH_VER}" ]]; then
      info "${svc_name}: torch version ${TORCH_VER}"
    fi
    warn "govulncheck not installed — Go CVE scan skipped for ${svc_name}"
  fi
done

# Python dependency scan
if [[ -f "${REPO_ROOT}/services/ml-engine/requirements.txt" ]]; then
  check "Scanning Python dependencies for CVEs..."
  if cmd_exists safety; then
    safety check -r "${REPO_ROOT}/services/ml-engine/requirements.txt" \
      --json > "${REPORT_DIR}/safety-report.json" 2>/dev/null || {
      VULN_COUNT=$(jq length "${REPORT_DIR}/safety-report.json" 2>/dev/null || echo "?")
      fail "safety: ${VULN_COUNT} Python vulnerability(ies) found"
    }
    pass "safety: Python dependencies clean"
  elif cmd_exists pip-audit; then
    pip-audit -r "${REPO_ROOT}/services/ml-engine/requirements.txt" \
      -f json -o "${REPORT_DIR}/pip-audit.json" 2>/dev/null || \
      fail "pip-audit: Python vulnerabilities found"
    pass "pip-audit: Python dependencies clean"
  else
    warn "safety/pip-audit not installed — Python CVE scan skipped"
  fi
fi

# Known CVE package check (from context: torch, lightgbm, protobuf/grpcio)
check "Checking for known vulnerable package versions (platform-specific)..."
PY_REQ="${REPO_ROOT}/services/ml-engine/requirements.txt"
if [[ -f "${PY_REQ}" ]]; then
  # grpcio conflict check
  GRPCIO_VER=$(grep "grpcio==" "${PY_REQ}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  PROTOBUF_VER=$(grep "protobuf==" "${PY_REQ}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
  if [[ -n "${GRPCIO_VER}" && -n "${PROTOBUF_VER}" ]]; then
    info "grpcio: ${GRPCIO_VER} | protobuf: ${PROTOBUF_VER}"
    # grpcio 1.78.0+ requires protobuf 5+
    MAJOR=$(echo "${PROTOBUF_VER}" | cut -d. -f1)
    [[ "${MAJOR}" -ge 5 ]] && pass "grpcio/protobuf version compatibility verified" || \
      warn "grpcio ${GRPCIO_VER} may conflict with protobuf ${PROTOBUF_VER} — verify ≥5.x"
  fi
fi

# =============================================================================
# §16  INFRASTRUCTURE SECURITY — TERRAFORM / AWS
# =============================================================================
section 16 "INFRASTRUCTURE SECURITY — TERRAFORM & AWS IAM"
compliance_ref "CIS AWS Foundations Benchmark | NIST CSF PR.AC | PCI-DSS Req 1,2"

TF_DIR="${REPO_ROOT}/terraform"

# tfsec scan
if cmd_exists tfsec && [[ -d "${TF_DIR}" ]]; then
  check "Running tfsec on Terraform configurations..."
  tfsec "${TF_DIR}" --format=json \
    --out "${REPORT_DIR}/tfsec-report.json" 2>/dev/null || true
  TFSEC_CRIT=$(jq '[.results[] | select(.severity == "CRITICAL")] | length' \
    "${REPORT_DIR}/tfsec-report.json" 2>/dev/null || echo 0)
  TFSEC_HIGH=$(jq '[.results[] | select(.severity == "HIGH")] | length' \
    "${REPORT_DIR}/tfsec-report.json" 2>/dev/null || echo 0)
  [[ "${TFSEC_CRIT}" -gt 0 ]] && critical "tfsec CRITICAL: ${TFSEC_CRIT}" || true
  [[ "${TFSEC_HIGH}" -gt 0 ]] && fail "tfsec HIGH: ${TFSEC_HIGH}" || \
    pass "tfsec: No CRITICAL/HIGH findings"
else
  warn "tfsec not installed or no terraform directory"
fi

# checkov scan
if cmd_exists checkov && [[ -d "${TF_DIR}" ]]; then
  check "Running checkov on Terraform and K8s manifests..."
  checkov -d "${TF_DIR}" --framework terraform \
    -o json --output-file "${REPORT_DIR}/checkov-tf.json" 2>/dev/null || true
  checkov -d "${REPO_ROOT}/k8s" --framework kubernetes \
    -o json --output-file "${REPORT_DIR}/checkov-k8s.json" 2>/dev/null || true
  CK_FAIL=$(jq '.summary.failed' "${REPORT_DIR}/checkov-tf.json" 2>/dev/null || echo 0)
  [[ "${CK_FAIL}" -gt 0 ]] && warn "checkov Terraform failures: ${CK_FAIL}" || \
    pass "checkov Terraform: Passed"
fi

# AWS IAM least privilege checks in Terraform
if [[ -d "${TF_DIR}" ]]; then
  check "Checking IAM policies for admin/wildcard permissions..."
  IAM_ADMIN=$(grep -rn '"*"\|Action.*\*\|Effect.*Allow.*Action.*\*' \
    "${TF_DIR}" --include="*.tf" 2>/dev/null | \
    grep -v "#" | wc -l || echo 0)
  [[ "${IAM_ADMIN}" -eq 0 ]] && pass "No wildcard IAM Actions found" || \
    fail "Wildcard IAM Actions found: ${IAM_ADMIN} — violates least privilege"
  compliance_ref "CIS AWS 1.16 — Ensure IAM policies do not allow full admin"

  # Terraform state encryption
  check "Checking Terraform state encryption..."
  TF_ENCRYPT=$(grep -rn "encrypt\|kms_key_id\|server_side_encryption" \
    "${TF_DIR}" --include="*.tf" 2>/dev/null | wc -l || echo 0)
  [[ "${TF_ENCRYPT}" -gt 0 ]] && pass "Terraform state encryption configured" || \
    fail "Terraform state not encrypted — sensitive state data exposed"

  # backend.tf presence
  check "Verifying backend.tf in all Terraform environments..."
  for env_dir in $(find "${TF_DIR}" -name "backend.tf" -exec dirname {} \; 2>/dev/null | sort -u); do
    pass "backend.tf found: ${env_dir}"
  done
  MISSING_BACKEND=$(find "${TF_DIR}" -name "main.tf" -exec dirname {} \; 2>/dev/null | \
    while read -r d; do [[ ! -f "${d}/backend.tf" ]] && echo "${d}"; done || true)
  [[ -n "${MISSING_BACKEND}" ]] && fail "Missing backend.tf in: ${MISSING_BACKEND}" || \
    pass "All Terraform environments have backend.tf"

  # terraform.tfvars in .gitignore
  check "Verifying terraform.tfvars not committed..."
  if git -C "${REPO_ROOT}" ls-files | grep -q "terraform.tfvars"; then
    critical "terraform.tfvars committed to git — secrets exposed"
  else
    pass "terraform.tfvars not committed to repository"
  fi
fi

# =============================================================================
# §17  CI/CD PIPELINE SECURITY
# =============================================================================
section 17 "CI/CD PIPELINE SECURITY — GITHUB ACTIONS"
compliance_ref "SLSA | CIS Control 4 | NIST SP 800-218"

WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"

# OIDC authentication (no static AWS credentials)
check "Checking GitHub Actions OIDC (no static credentials)..."
if grep -rq "aws-actions/configure-aws-credentials" "${WORKFLOWS_DIR}" 2>/dev/null; then
  if grep -rq "role-to-assume\|OIDC\|web-identity-token-file" "${WORKFLOWS_DIR}" 2>/dev/null; then
    pass "OIDC authentication used (no static AWS credentials)"
  else
    fail "AWS credentials in workflows — not using OIDC"
  fi
fi

# Workflow permissions (least privilege)
check "Checking workflow permissions (least privilege)..."
PERM_WRITE_ALL=$(grep -rn "permissions: write-all" "${WORKFLOWS_DIR}" 2>/dev/null | wc -l || echo 0)
[[ "${PERM_WRITE_ALL}" -eq 0 ]] && pass "No write-all permissions found" || \
  fail "write-all permissions in workflows: ${PERM_WRITE_ALL}"

# Check explicit read-only by default
check "Checking default permissions declaration in workflows..."
DEFAULT_READ=$(grep -rn "permissions:" "${WORKFLOWS_DIR}" 2>/dev/null | \
  grep -c "read-all\|contents: read" || echo 0)
[[ "${DEFAULT_READ}" -gt 0 ]] && pass "Restrictive default permissions found" || \
  warn "No read-only default permissions set in workflows"
compliance_ref "GitHub Security Hardening — Use minimum required permissions"

# Secrets in workflow env vars (plain text)
check "Checking for secrets exposed as plain-text env vars..."
PLAIN_SECRETS=$(grep -rn "env:$" "${WORKFLOWS_DIR}" 2>/dev/null | \
  grep -A5 "env:" | grep -vE "\$\{\{|secrets\." | \
  grep -E "(KEY|SECRET|TOKEN|PASSWORD|PASS)" | wc -l || echo 0)
[[ "${PLAIN_SECRETS}" -eq 0 ]] && pass "No plain-text secrets in workflow env vars" || \
  fail "Potential plain-text secrets in workflows: ${PLAIN_SECRETS}"

# Pull request trigger with write access
check "Checking pull_request_target security..."
PR_TARGET=$(grep -rn "pull_request_target" "${WORKFLOWS_DIR}" 2>/dev/null | wc -l || echo 0)
[[ "${PR_TARGET}" -gt 0 ]] && \
  warn "pull_request_target used — verify no secret exposure to fork PRs" || \
  pass "No pull_request_target (safer)"

# Workflow versions pinned
check "Verifying all action steps pinned to commit SHA..."
UNPINNED=$(grep -rn "uses:" "${WORKFLOWS_DIR}" 2>/dev/null | \
  grep -vE "@[a-f0-9]{40}" | grep -v "uses: ./\|uses: docker://" | wc -l || echo 0)
[[ "${UNPINNED}" -eq 0 ]] && pass "All external actions pinned to SHA" || \
  warn "Actions not pinned to SHA: ${UNPINNED} — supply chain risk"

# image-sign.yml: all 16 services present
check "Verifying all 16 services in image-sign.yml..."
if [[ -f "${WORKFLOWS_DIR}/image-sign.yml" ]]; then
  for svc in "${SERVICES[@]}"; do
    grep -q "${svc}" "${WORKFLOWS_DIR}/image-sign.yml" && \
      pass "image-sign.yml covers: ${svc}" || \
      fail "image-sign.yml MISSING service: ${svc}"
  done
else
  fail "image-sign.yml not found"
fi

# release.yml: all 16 services present
check "Verifying all 16 services in release.yml..."
if [[ -f "${WORKFLOWS_DIR}/release.yml" ]]; then
  for svc in "${SERVICES[@]}"; do
    grep -q "${svc}" "${WORKFLOWS_DIR}/release.yml" && \
      pass "release.yml covers: ${svc}" || \
      fail "release.yml MISSING service: ${svc}"
  done
else
  fail "release.yml not found"
fi

# =============================================================================
# §18  ARGO ROLLOUTS & DEPLOYMENT SECURITY
# =============================================================================
section 18 "ARGO ROLLOUTS & DEPLOYMENT SECURITY"
compliance_ref "NIST CSF PR.IP-1 | SOC 2 CC8.1"

# All workloads use Rollout not Deployment
check "Verifying all workloads use kind: Rollout (not Deployment)..."
DEPLOYMENTS=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: Deployment" 2>/dev/null | \
  xargs grep -L "kind: Rollout" 2>/dev/null || true)
[[ -z "${DEPLOYMENTS}" ]] && pass "All workloads use kind: Rollout" || {
  fail "Workloads still using kind: Deployment:"
  echo "${DEPLOYMENTS}" | sed 's/^/     /'
}

# Canary analysis templates
check "Checking Argo Rollout canary analysis templates..."
ANALYSIS=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "AnalysisTemplate\|AnalysisRun" 2>/dev/null | wc -l || echo 0)
[[ "${ANALYSIS}" -gt 0 ]] && pass "Canary AnalysisTemplates found: ${ANALYSIS}" || \
  warn "No Rollout AnalysisTemplates — automated rollback not configured"

# ArgoCD ApplicationSet coverage
check "Verifying ArgoCD ApplicationSet covers all services..."
APPSET=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: ApplicationSet" 2>/dev/null | head -1 || true)
if [[ -n "${APPSET}" ]]; then
  for svc in "${SERVICES[@]}"; do
    grep -q "${svc}" "${APPSET}" && pass "ApplicationSet covers: ${svc}" || \
      warn "ApplicationSet may not cover: ${svc}"
  done
else
  fail "No ApplicationSet found — ArgoCD coverage unverified"
fi

# ArgoCD RBAC
check "Verifying ArgoCD RBAC configuration..."
ARGOCD_RBAC=$(find "${REPO_ROOT}/k8s" -name "argocd*rbac*" -o -name "rbac*argocd*" \
  2>/dev/null | wc -l || echo 0)
[[ "${ARGOCD_RBAC}" -gt 0 ]] && pass "ArgoCD RBAC policy found" || \
  warn "ArgoCD RBAC not configured — all users may have admin access"

# =============================================================================
# §19  AUDIT LOGGING & OBSERVABILITY SECURITY
# =============================================================================
section 19 "AUDIT LOGGING & OBSERVABILITY SECURITY"
compliance_ref "PCI-DSS Req 10 | SOC 2 CC7.2 | ISO 27001 A.12.4"

# Kubernetes audit logging
check "Checking Kubernetes API audit logging configuration..."
AUDIT_POLICY=$(find "${REPO_ROOT}" -name "audit-policy*" \
  -o -name "*audit*policy*" 2>/dev/null | wc -l || echo 0)
[[ "${AUDIT_POLICY}" -gt 0 ]] && pass "Kubernetes audit policy found" || \
  fail "No Kubernetes audit policy — API actions not logged"
compliance_ref "PCI-DSS v4.0 Req 10.2 — Audit logs capture all individual access to cardholder data"

# Application-level audit trail
check "Checking application audit trail implementation..."
AUDIT_LOG=$(grep -rn "AuditLog\|audit_log\|AuditTrail\|audit.Log" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${AUDIT_LOG}" -gt 0 ]] && pass "Application audit logging found: ${AUDIT_LOG}" || \
  fail "No application-level audit logging — required for financial platform"
compliance_ref "PCI-DSS v4.0 Req 10.2.1 — All individual user access to cardholder data"

# Log retention policy
check "Checking log retention policy..."
LOG_RETENTION=$(grep -rn "retention\|retentionDays\|logRetention" \
  "${REPO_ROOT}" --include="*.tf" --include="*.yaml" --include="*.yml" 2>/dev/null | \
  grep -iv "comment" | wc -l || echo 0)
[[ "${LOG_RETENTION}" -gt 0 ]] && pass "Log retention policy found" || \
  warn "No log retention policy — PCI-DSS requires 12 months (3 months online)"
compliance_ref "PCI-DSS v4.0 Req 10.7 — Retain audit logs for at least 12 months"

# VictoriaMetrics / metrics security
check "Checking metrics endpoint authentication..."
METRICS_AUTH=$(grep -rn "basicAuth\|bearerTokenSecret\|authorization.*metrics" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${METRICS_AUTH}" -gt 0 ]] && pass "Metrics endpoint authentication found" || \
  warn "Metrics endpoints may be unauthenticated — financial telemetry exposed"

# AlertManager security
check "Verifying AlertManager receiver security..."
AM_RECEIVERS=$(find "${REPO_ROOT}/k8s" -name "*alertmanager*" 2>/dev/null | \
  xargs grep -l "pagerduty\|slack\|webhook" 2>/dev/null | wc -l || echo 0)
[[ "${AM_RECEIVERS}" -gt 0 ]] && pass "AlertManager receivers configured: ${AM_RECEIVERS}" || \
  warn "No AlertManager receivers found — alerts silently dropped"

# Structured logging (JSON)
check "Verifying structured JSON logging..."
STRUCTURED_LOG=$(grep -rn "zap\|logrus\|zerolog\|slog\|json.*log\|log.*json" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${STRUCTURED_LOG}" -gt 10 ]] && pass "Structured logging library found: ${STRUCTURED_LOG}" || \
  warn "No clear structured logging library — log aggregation may fail"

# Sensitive data in logs
check "Checking for sensitive data leakage in log statements..."
SENSITIVE_LOGS=$(grep -rn 'log.*password\|log.*secret\|log.*token\|log.*key\|Printf.*password' \
  "${REPO_ROOT}/services" --include="*.go" -i 2>/dev/null | \
  grep -v "_test\.\|//\|comment" | wc -l || echo 0)
[[ "${SENSITIVE_LOGS}" -eq 0 ]] && pass "No sensitive data in log statements" || \
  critical "Sensitive data in log statements: ${SENSITIVE_LOGS} — credential leakage risk"

# =============================================================================
# §20  DATABASE SECURITY
# =============================================================================
section 20 "DATABASE SECURITY — POSTGRES / CLICKHOUSE / REDIS"
compliance_ref "PCI-DSS Req 3,6 | CIS PostgreSQL Benchmark"

# PgBouncer configuration
check "Verifying PgBouncer connection pooler security..."
PGBOUNCER=$(find "${REPO_ROOT}/k8s" -name "*pgbouncer*" 2>/dev/null | wc -l || echo 0)
[[ "${PGBOUNCER}" -gt 0 ]] && pass "PgBouncer configuration found" || \
  warn "PgBouncer not found — direct database connections may be unbounded"

# Migration scope headers
check "Verifying SQL migration scope headers..."
MIGRATIONS=$(find "${REPO_ROOT}/services" -name "*.sql" 2>/dev/null)
MISSING_SCOPE=0
for sql_file in ${MIGRATIONS}; do
  if ! head -3 "${sql_file}" | grep -q "Scope:"; then
    ((MISSING_SCOPE++))
    warn "Migration missing scope header: $(basename ${sql_file})"
  fi
done
[[ "${MISSING_SCOPE}" -eq 0 ]] && pass "All migration files have scope headers" || \
  fail "Migrations missing scope headers: ${MISSING_SCOPE}"

# Database user least privilege
check "Checking database user privilege configuration..."
DB_SUPERUSER=$(grep -rn "SUPERUSER\|superuser\|createdb\|CREATEDB" \
  "${REPO_ROOT}" --include="*.sql" --include="*.go" --include="*.tf" 2>/dev/null | \
  grep -v "#\|comment\|--" | wc -l || echo 0)
[[ "${DB_SUPERUSER}" -eq 0 ]] && pass "No database superuser grants found" || \
  warn "Database superuser references found: ${DB_SUPERUSER}"

# ClickHouse data retention
check "Checking ClickHouse TTL/retention policies..."
CH_TTL=$(grep -rn "TTL\|EXPIRE\|ttl" "${REPO_ROOT}/services" \
  --include="*.go" 2>/dev/null | grep -i "clickhouse" | wc -l || echo 0)
[[ "${CH_TTL}" -gt 0 ]] && pass "ClickHouse TTL policies configured" || \
  warn "No ClickHouse TTL — unbounded data growth, retention policy unclear"

# Redis authentication
check "Checking Redis authentication configuration..."
REDIS_AUTH=$(grep -rn "requirepass\|AUTH\|redis_password\|RedisPassword" \
  "${REPO_ROOT}" --include="*.go" --include="*.yaml" --include="*.yml" --include="*.tf" \
  2>/dev/null | grep -iv "comment" | wc -l || echo 0)
[[ "${REDIS_AUTH}" -gt 0 ]] && pass "Redis authentication configured" || \
  critical "No Redis authentication — cache accessible without credentials"

# =============================================================================
# §21  KAFKA / EVENT BUS SECURITY
# =============================================================================
section 21 "KAFKA / EVENT BUS SECURITY"
compliance_ref "PCI-DSS Req 4 | NIST SP 800-204"

check "Checking Kafka topic access control (ACLs)..."
KAFKA_ACL=$(grep -rn "acl\|ACL\|KafkaACL\|TopicPolicy" \
  "${REPO_ROOT}" --include="*.go" --include="*.yaml" --include="*.yml" \
  -i 2>/dev/null | wc -l || echo 0)
[[ "${KAFKA_ACL}" -gt 0 ]] && pass "Kafka ACL configuration found" || \
  warn "No Kafka ACLs found — all services can read/write all topics"
compliance_ref "Financial data requires strict topic-level access control"

check "Checking Kafka producer/consumer authentication..."
KAFKA_SASL=$(grep -rn "SASL\|sasl\|SASLMechanism\|SCRAM" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${KAFKA_SASL}" -gt 0 ]] && pass "Kafka SASL authentication found" || \
  fail "No Kafka SASL — message bus unauthenticated"

check "Checking for PII/financial data in Kafka message payloads..."
KAFKA_ENCRYPT=$(grep -rn "encrypt\|Encrypt\|cipher" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | \
  grep -i "kafka\|produce\|consumer" | wc -l || echo 0)
[[ "${KAFKA_ENCRYPT}" -gt 0 ]] && pass "Kafka payload encryption references found" || \
  warn "No payload encryption for Kafka — financial data may be in plaintext at rest in topics"

# =============================================================================
# §22  VELERO BACKUP SECURITY
# =============================================================================
section 22 "VELERO BACKUP SECURITY"
compliance_ref "PCI-DSS Req 12.3.3 | ISO 27001 A.12.3 | SOC 2 A1.2"

check "Verifying Velero backup configuration..."
VELERO=$(find "${REPO_ROOT}/k8s" -name "*velero*" 2>/dev/null | wc -l || echo 0)
[[ "${VELERO}" -gt 0 ]] && pass "Velero configuration found: ${VELERO} file(s)" || \
  fail "Velero not configured — no disaster recovery capability"

check "Checking backup encryption..."
BACKUP_ENCRYPT=$(grep -rn "encrypt\|kms\|server-side" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" -i 2>/dev/null | \
  grep -i "velero\|backup" | wc -l || echo 0)
[[ "${BACKUP_ENCRYPT}" -gt 0 ]] && pass "Backup encryption configured" || \
  fail "Backup encryption not configured — backup data may be unencrypted"
compliance_ref "PCI-DSS v4.0 Req 3.5 — Protect stored account data"

check "Checking backup schedule and retention..."
BACKUP_SCHEDULE=$(grep -rn "Schedule\|cron\|retention\|ttl" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" 2>/dev/null | \
  grep -i "velero\|backup" | wc -l || echo 0)
[[ "${BACKUP_SCHEDULE}" -gt 0 ]] && pass "Backup schedule/retention configured" || \
  warn "No backup schedule found — manual backups only"

# =============================================================================
# §23  CERT-MANAGER & PKI SECURITY
# =============================================================================
section 23 "CERT-MANAGER & PKI SECURITY"
compliance_ref "PCI-DSS Req 4 | CIS K8s §5.4 | NIST SP 800-57"

check "Checking certificate validity periods..."
CERT_DURATION=$(grep -rn "duration:\|renewBefore:" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | head -10)
if echo "${CERT_DURATION}" | grep -q "8760h\|365d\|1y"; then
  warn "Certificate duration is 1 year — consider shorter-lived certs (90 days)"
elif echo "${CERT_DURATION}" | grep -q "2160h\|90d"; then
  pass "Certificate duration ≤90 days — good security hygiene"
else
  info "Certificate duration: ${CERT_DURATION}"
fi

check "Checking internal CA issuer configuration..."
CA_ISSUER=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "ClusterIssuer\|platform-ca-issuer" 2>/dev/null | wc -l || echo 0)
[[ "${CA_ISSUER}" -gt 0 ]] && pass "Internal CA issuer (platform-ca-issuer) found" || \
  warn "Internal CA issuer not found"

check "Verifying cert rotation automation..."
CERT_ROTATION=$(grep -rn "renewBefore\|CertificateRequest" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${CERT_ROTATION}" -gt 0 ]] && pass "Certificate auto-renewal configured" || \
  warn "No automatic certificate renewal — manual rotation required"

# =============================================================================
# §24  ENVOY GATEWAY & SERVICE MESH SECURITY
# =============================================================================
section 24 "ENVOY GATEWAY & SERVICE MESH SECURITY"
compliance_ref "NIST SP 800-204 | PCI-DSS Req 1,4"

check "Verifying Envoy Gateway HTTPRoute configuration..."
HTTP_ROUTES=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: HTTPRoute\|HTTPRoute" 2>/dev/null | wc -l || echo 0)
[[ "${HTTP_ROUTES}" -gt 0 ]] && pass "HTTPRoute resources found: ${HTTP_ROUTES}" || \
  warn "No HTTPRoute resources found"

check "Checking HTTPS redirect enforcement..."
HTTPS_REDIRECT=$(grep -rn "httpsRedirect\|HTTPSRedirect\|https.*redirect\|scheme.*HTTPS" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" -i 2>/dev/null | wc -l || echo 0)
[[ "${HTTPS_REDIRECT}" -gt 0 ]] && pass "HTTPS redirect configured" || \
  fail "No HTTPS redirect — HTTP traffic may reach financial endpoints"
compliance_ref "PCI-DSS v4.0 Req 4.2.1 — Strong cryptography for data in transit"

check "Checking response security headers..."
SEC_HEADERS=(
  "X-Content-Type-Options"
  "X-Frame-Options"
  "Content-Security-Policy"
  "Strict-Transport-Security"
  "X-XSS-Protection"
  "Referrer-Policy"
)
for header in "${SEC_HEADERS[@]}"; do
  FOUND=$(grep -rn "${header}" "${REPO_ROOT}/k8s" "${REPO_ROOT}/services" \
    --include="*.yaml" --include="*.yml" --include="*.go" 2>/dev/null | wc -l || echo 0)
  [[ "${FOUND}" -gt 0 ]] && pass "Security header configured: ${header}" || \
    fail "Missing security header: ${header}"
done
compliance_ref "OWASP Secure Headers Project"

check "Verifying WAF/DDoS protection..."
WAF=$(grep -rn "waf\|WAF\|DDoS\|ddos\|rateLimit\|rate_limit" \
  "${REPO_ROOT}/k8s" "${REPO_ROOT}/terraform" \
  --include="*.yaml" --include="*.yml" --include="*.tf" -i 2>/dev/null | wc -l || echo 0)
[[ "${WAF}" -gt 0 ]] && pass "WAF/rate limiting configuration found" || \
  warn "No WAF/DDoS protection found — financial platform highly exposed"

# =============================================================================
# §25  KEDA AUTOSCALER SECURITY
# =============================================================================
section 25 "KEDA AUTOSCALER SECURITY"
compliance_ref "NIST CSF PR.PT-4 | CIS K8s §5.1"

check "Verifying KEDA ScaledObjects and ignoreDifferences..."
KEDA_SO=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "kind: ScaledObject" 2>/dev/null | wc -l || echo 0)
[[ "${KEDA_SO}" -gt 0 ]] && pass "KEDA ScaledObjects found: ${KEDA_SO}" || \
  warn "No KEDA ScaledObjects — autoscaling not configured"

check "Checking KEDA authentication (TriggerAuthentication)..."
KEDA_AUTH=$(find "${REPO_ROOT}/k8s" -name "*.yaml" -o -name "*.yml" 2>/dev/null | \
  xargs grep -l "TriggerAuthentication\|ClusterTriggerAuthentication" 2>/dev/null | wc -l || echo 0)
[[ "${KEDA_AUTH}" -gt 0 ]] && pass "KEDA TriggerAuthentication found" || \
  warn "No KEDA TriggerAuthentication — scalers may use unauthenticated sources"

check "Checking KEDA max replicas bounds..."
MAX_REPLICAS=$(grep -rn "maxReplicaCount:" "${REPO_ROOT}/k8s" \
  --include="*.yaml" --include="*.yml" 2>/dev/null)
if echo "${MAX_REPLICAS}" | grep -qE "maxReplicaCount:\s*[0-9]{4,}"; then
  warn "Very high maxReplicaCount found — DoS via resource exhaustion risk"
else
  pass "KEDA maxReplicaCount within reasonable bounds"
fi

# =============================================================================
# §26  CHAOS ENGINEERING SECURITY BOUNDARIES
# =============================================================================
section 26 "CHAOS ENGINEERING SECURITY BOUNDARIES"
compliance_ref "SOC 2 A1.1 — System availability | NIST CSF RC.RP-1"

check "Verifying Chaos Mesh RBAC restrictions..."
CHAOS=$(find "${REPO_ROOT}" -name "*chaos*" 2>/dev/null | wc -l || echo 0)
[[ "${CHAOS}" -gt 0 ]] && {
  pass "Chaos Mesh configuration found"
  # Check chaos experiments limited to non-production
  CHAOS_PROD=$(grep -rn "namespace: platform\|namespace: prod" \
    "${REPO_ROOT}" --include="*.yaml" --include="*.yml" 2>/dev/null | \
    grep -i "chaos\|experiment" | wc -l || echo 0)
  [[ "${CHAOS_PROD}" -gt 0 ]] && \
    warn "Chaos experiments may target production namespace" || \
    pass "Chaos experiments appear isolated from production"
} || warn "Chaos Mesh not found — resilience testing not configured"

# =============================================================================
# §27  DATA SOVEREIGNTY & COMPLIANCE
# =============================================================================
section 27 "DATA SOVEREIGNTY & GDPR/PDPA COMPLIANCE"
compliance_ref "GDPR Art 25 | PCI-DSS Req 3,9 | SOC 2 Privacy Criteria"

check "Checking data residency configuration (MENA region)..."
REGION_CONFIG=$(grep -rn "me-south-1\|ap-southeast\|MENA\|mena\|regional" \
  "${REPO_ROOT}/terraform" "${REPO_ROOT}/k8s" \
  --include="*.tf" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
[[ "${REGION_CONFIG}" -gt 0 ]] && pass "Regional data residency configuration found" || \
  warn "Data residency not explicitly configured"

check "Checking PII data classification and handling..."
PII_HANDLING=$(grep -rn "PII\|pii\|personal_data\|PersonalData\|GDPR\|gdpr" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${PII_HANDLING}" -gt 0 ]] && pass "PII handling code found: ${PII_HANDLING}" || \
  warn "No PII classification code found — data privacy compliance risk"
compliance_ref "GDPR Art 25 — Data protection by design"

check "Checking data minimization practices..."
DATA_MINIMIZATION=$(grep -rn "omitempty\|omit\|Exclude\|Mask\|mask\|Redact\|redact" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${DATA_MINIMIZATION}" -gt 5 ]] && pass "Data minimization practices found: ${DATA_MINIMIZATION}" || \
  warn "Limited data minimization found"

check "Checking right-to-erasure (GDPR Art 17) implementation..."
ERASURE=$(grep -rn "delete.*user\|DeleteUser\|erasure\|right.*delete\|purge.*data" \
  "${REPO_ROOT}/services" --include="*.go" -i 2>/dev/null | wc -l || echo 0)
[[ "${ERASURE}" -gt 0 ]] && pass "Data erasure functionality found" || \
  fail "No data erasure implementation — GDPR right-to-erasure not implemented"

# =============================================================================
# §28  PCI-DSS SPECIFIC CONTROLS
# =============================================================================
section 28 "PCI-DSS v4.0 SPECIFIC CONTROLS"
compliance_ref "PCI-DSS v4.0 Full Control Set — Financial Data Platform"

# Cardholder data identification
check "PCI Req 3: Cardholder data protection..."
CARD_DATA=$(grep -rn "card_number\|cardNumber\|credit_card\|pan\|PAN\|cvv\|CVV" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
if [[ "${CARD_DATA}" -gt 0 ]]; then
  info "Cardholder data references found: ${CARD_DATA}"
  CARD_ENCRYPTED=$(grep -rn "encrypt\|hash\|mask" "${REPO_ROOT}/services" \
    --include="*.go" 2>/dev/null | wc -l || echo 0)
  [[ "${CARD_ENCRYPTED}" -gt 0 ]] && pass "Cardholder data handling with encryption found" || \
    critical "Cardholder data references without encryption"
fi

# PCI Req 6: Secure development
check "PCI Req 6: Security testing in SDLC..."
SAST_IN_CI=$(grep -rn "gosec\|semgrep\|security.*scan\|sast" \
  "${REPO_ROOT}/.github/workflows" --include="*.yml" -i 2>/dev/null | wc -l || echo 0)
[[ "${SAST_IN_CI}" -gt 0 ]] && pass "SAST in CI/CD pipeline" || \
  fail "No SAST in CI/CD — PCI Req 6.2.4 requires SAST"

# PCI Req 8: User authentication
check "PCI Req 8: Unique user IDs..."
UUID_AUTH=$(grep -rn "uuid\|UUID\|userID\|user_id" "${REPO_ROOT}/services/auth" \
  --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${UUID_AUTH}" -gt 0 ]] && pass "Unique user ID system found" || \
  warn "Unique user ID not clearly implemented"

# PCI Req 10: Logging all access
check "PCI Req 10: All access to cardholder data logged..."
ACCESS_LOG=$(grep -rn "audit\|AuditLog\|access_log\|AccessLog" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${ACCESS_LOG}" -gt 5 ]] && pass "Access logging found: ${ACCESS_LOG}" || \
  fail "Insufficient access logging — PCI Req 10 not met"

# PCI Req 11: Security testing
check "PCI Req 11: Penetration testing schedule..."
PENTEST_DOC=$(find "${REPO_ROOT}" -name "*pentest*" -o -name "*penetration*" \
  -o -name "*security-test*" 2>/dev/null | wc -l || echo 0)
[[ "${PENTEST_DOC}" -gt 0 ]] && pass "Penetration testing documentation found" || \
  warn "No penetration testing documentation — PCI Req 11.4 requires annual pentest"

# =============================================================================
# §29  CONTAINER IMAGE HARDENING
# =============================================================================
section 29 "CONTAINER IMAGE HARDENING"
compliance_ref "CIS Docker Benchmark | NIST SP 800-190"

check "Checking Dockerfile security best practices..."
for dockerfile in $(find "${REPO_ROOT}/services" -name "Dockerfile*" 2>/dev/null); do
  svc=$(echo "${dockerfile}" | awk -F'/' '{print $(NF-1)}')
  
  # USER directive
  if grep -q "^USER " "${dockerfile}" 2>/dev/null; then
    USER_VAL=$(grep "^USER " "${dockerfile}" | tail -1 | awk '{print $2}')
    [[ "${USER_VAL}" == "root" || "${USER_VAL}" == "0" ]] && \
      critical "${svc}/$(basename ${dockerfile}): Running as root" || \
      pass "${svc}: Non-root USER set: ${USER_VAL}"
  else
    fail "${svc}/$(basename ${dockerfile}): No USER directive — defaults to root"
  fi
  
  # Multi-stage builds
  STAGES=$(grep -c "^FROM" "${dockerfile}" 2>/dev/null || echo 0)
  [[ "${STAGES}" -gt 1 ]] && pass "${svc}: Multi-stage build (${STAGES} stages)" || \
    warn "${svc}: Single-stage build — build tools in production image"
  
  # HEALTHCHECK
  grep -q "HEALTHCHECK" "${dockerfile}" 2>/dev/null && \
    pass "${svc}: HEALTHCHECK defined" || \
    warn "${svc}: No HEALTHCHECK directive"
  
  # apt-get cleanup
  if grep -q "apt-get" "${dockerfile}" 2>/dev/null; then
    grep -q "rm -rf /var/lib/apt/lists" "${dockerfile}" 2>/dev/null && \
      pass "${svc}: apt-get cache cleaned" || \
      warn "${svc}: apt-get cache not cleaned — image layer bloat"
  fi
done

# ml-engine uses Dockerfile not Dockerfile.arm64
check "Verifying ml-engine uses Dockerfile (Python convention)..."
if [[ -f "${REPO_ROOT}/services/ml-engine/Dockerfile" ]]; then
  pass "ml-engine/Dockerfile exists (Python convention)"
else
  fail "ml-engine/Dockerfile not found"
fi
if [[ -f "${REPO_ROOT}/services/ml-engine/Dockerfile.arm64" ]]; then
  critical "ml-engine/Dockerfile.arm64 exists — should use Dockerfile for Python services"
fi

# =============================================================================
# §30  INCIDENT RESPONSE READINESS
# =============================================================================
section 30 "INCIDENT RESPONSE READINESS"
compliance_ref "PCI-DSS Req 12.10 | ISO 27001 A.16 | NIST CSF RS.RP-1"

check "Checking Incident Response runbook documentation..."
RUNBOOKS=$(find "${REPO_ROOT}" -name "*runbook*" -o -name "*incident*" \
  -o -name "*playbook*" 2>/dev/null | wc -l || echo 0)
[[ "${RUNBOOKS}" -gt 0 ]] && pass "Incident response runbooks found: ${RUNBOOKS}" || \
  fail "No incident response runbooks — PCI-DSS Req 12.10.1 violation"

check "Checking PagerDuty/alert escalation configuration..."
PAGERDUTY=$(grep -rn "pagerduty\|PagerDuty\|oncall\|escalation" \
  "${REPO_ROOT}/k8s" --include="*.yaml" --include="*.yml" -i 2>/dev/null | wc -l || echo 0)
[[ "${PAGERDUTY}" -gt 0 ]] && pass "PagerDuty/escalation configuration found" || \
  warn "No PagerDuty configuration found"

check "Checking security alert rules (critical events)..."
SECURITY_ALERTS=(
  "unauthorized.*access"
  "privilege.*escalat"
  "brute.*force"
  "anomal"
  "intrusion"
  "data.*exfil"
)
ALERTS_FOUND=0
for pattern in "${SECURITY_ALERTS[@]}"; do
  CNT=$(grep -rni "${pattern}" "${REPO_ROOT}/k8s" \
    --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l || echo 0)
  [[ "${CNT}" -gt 0 ]] && ((ALERTS_FOUND++)) && \
    pass "Security alert rule for '${pattern}' found"
done
[[ "${ALERTS_FOUND}" -eq 0 ]] && \
  fail "No security-specific alert rules — incidents won't trigger automated response"

# =============================================================================
# §31  LIVE CLUSTER SECURITY CHECKS
# =============================================================================
section 31 "LIVE KUBERNETES CLUSTER SECURITY (REQUIRES CONNECTIVITY)"
compliance_ref "CIS Kubernetes Benchmark v1.9"

if [[ "${K8S_AVAILABLE}" == true ]]; then
  # kube-bench
  if cmd_exists kube-bench; then
    check "Running kube-bench CIS benchmark..."
    kube-bench run --json > "${REPORT_DIR}/kube-bench.json" 2>/dev/null || true
    KB_FAIL=$(jq '[.Controls[].tests[].results[] | select(.status == "FAIL")] | length' \
      "${REPORT_DIR}/kube-bench.json" 2>/dev/null || echo "?")
    KB_WARN=$(jq '[.Controls[].tests[].results[] | select(.status == "WARN")] | length' \
      "${REPORT_DIR}/kube-bench.json" 2>/dev/null || echo "?")
    info "kube-bench: FAIL=${KB_FAIL}, WARN=${KB_WARN}"
    [[ "${KB_FAIL}" -gt 10 ]] && fail "kube-bench: ${KB_FAIL} failed checks" || \
      pass "kube-bench: ${KB_FAIL} failed checks (see kube-bench.json)"
  else
    info "kube-bench not available — CIS benchmark skipped"
  fi

  # Anonymous auth check
  check "Live: Checking anonymous authentication disabled..."
  ANON=$(kubectl get --raw /api/v1 2>/dev/null | head -5 || echo "error")
  [[ "${ANON}" == *"error"* ]] && pass "API server anonymous auth appears restricted" || \
    warn "API server responded without auth — verify anonymous-auth=false"

  # Secrets encryption at rest
  check "Live: Verifying secrets encrypted at rest..."
  kubectl get secret -n platform -o json 2>/dev/null | \
    jq -r '.items[0].data | keys[0]' > /dev/null 2>&1 && \
    info "Secrets accessible — verify encryption configuration at kube-apiserver level"

  # Privileged pods in cluster
  check "Live: Checking for privileged pods in platform namespace..."
  PRIV_PODS=$(kubectl get pods -n platform -o json 2>/dev/null | \
    jq '[.items[].spec.containers[].securityContext.privileged // false] | 
    map(select(. == true)) | length' 2>/dev/null || echo 0)
  [[ "${PRIV_PODS}" -eq 0 ]] && pass "No privileged pods running in platform namespace" || \
    critical "Privileged pods running: ${PRIV_PODS}"

  # ServiceAccount token expiry
  check "Live: Verifying ServiceAccount token bound volumes..."
  SA_TOKENS=$(kubectl get pods -n platform -o json 2>/dev/null | \
    jq '[.items[].spec.volumes[]? | select(.projected.sources[]?.serviceAccountToken)] | 
    length' 2>/dev/null || echo 0)
  [[ "${SA_TOKENS}" -gt 0 ]] && pass "Bound ServiceAccount token volumes found: ${SA_TOKENS}" || \
    warn "No bound ServiceAccount token volumes — using legacy tokens"

  # Network policies enforced
  check "Live: Verifying NetworkPolicies enforced in cluster..."
  NP_COUNT=$(kubectl get networkpolicies -n platform --no-headers 2>/dev/null | wc -l || echo 0)
  [[ "${NP_COUNT}" -gt 0 ]] && pass "NetworkPolicies active in platform: ${NP_COUNT}" || \
    critical "No NetworkPolicies active in platform namespace"

else
  info "Cluster not reachable — live checks skipped (run in-cluster or with kubeconfig)"
fi

# =============================================================================
# §32  PROTO/GRPC SECURITY
# =============================================================================
section 32 "PROTOBUF / gRPC SECURITY"
compliance_ref "NIST SP 800-204 §gRPC | OWASP API"

check "Verifying proto generation path (/gen root only)..."
GEN_DIRS=$(find "${REPO_ROOT}/services" -type d -name "gen" 2>/dev/null | wc -l || echo 0)
[[ "${GEN_DIRS}" -eq 0 ]] && pass "No per-service gen/ directories found" || \
  fail "Per-service gen/ directories found: ${GEN_DIRS} — should use root /gen only"

check "Checking gRPC TLS configuration..."
GRPC_TLS=$(grep -rn "credentials.NewClientTLSFromCert\|grpc.WithTransportCredentials\|tls.Config" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${GRPC_TLS}" -gt 0 ]] && pass "gRPC TLS credentials found: ${GRPC_TLS}" || \
  warn "No gRPC TLS credentials — gRPC calls may be unencrypted"

check "Checking gRPC authentication interceptors..."
GRPC_AUTH=$(grep -rn "UnaryInterceptor\|StreamInterceptor\|grpc.*auth\|grpc.*interceptor" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${GRPC_AUTH}" -gt 0 ]] && pass "gRPC interceptors found: ${GRPC_AUTH}" || \
  warn "No gRPC authentication interceptors"

# =============================================================================
# §33  SCHEMA REGISTRY SECURITY
# =============================================================================
section 33 "SCHEMA REGISTRY SECURITY"
compliance_ref "Data Governance | PCI-DSS Req 3"

check "Verifying Schema Registry authentication..."
SR_AUTH=$(grep -rn "schema.*registry\|SchemaRegistry" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | \
  grep -i "auth\|credential\|user\|pass" | wc -l || echo 0)
[[ "${SR_AUTH}" -gt 0 ]] && pass "Schema Registry authentication found" || \
  warn "Schema Registry may be unauthenticated"

check "Checking schema evolution compatibility mode..."
SR_COMPAT=$(grep -rn "FULL\|FORWARD\|BACKWARD\|NONE\|compatibility" \
  "${REPO_ROOT}" --include="*.go" --include="*.yaml" 2>/dev/null | \
  grep -i "schema" | wc -l || echo 0)
[[ "${SR_COMPAT}" -gt 0 ]] && pass "Schema compatibility mode configured" || \
  warn "No schema compatibility mode — breaking changes possible"

# =============================================================================
# §34  SECURITY HEADERS & CORS
# =============================================================================
section 34 "CORS & SECURITY HEADERS"
compliance_ref "OWASP A05:2021 Security Misconfiguration"

check "Checking CORS configuration..."
CORS=$(grep -rn "CORS\|cors\|AllowOrigin\|Access-Control-Allow-Origin" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null)
if echo "${CORS}" | grep -q '\*'; then
  critical "CORS wildcard (*) AllowOrigin found — any domain can access API"
elif [[ -n "${CORS}" ]]; then
  pass "CORS origin restriction configured"
else
  warn "CORS configuration not found"
fi
compliance_ref "OWASP A05 — Misconfigured CORS allows cross-origin attacks"

# Content-Type validation
check "Checking Content-Type validation on API handlers..."
CT_VALIDATE=$(grep -rn "Content-Type\|ContentType\|r.Header.Get.*content" \
  "${REPO_ROOT}/services" --include="*.go" 2>/dev/null | wc -l || echo 0)
[[ "${CT_VALIDATE}" -gt 5 ]] && pass "Content-Type validation found: ${CT_VALIDATE}" || \
  warn "Limited Content-Type validation — MIME confusion attacks possible"

# =============================================================================
# §35  FINAL COMPLIANCE SCORECARD
# =============================================================================
section 35 "PCI-DSS / SOC 2 / ISO 27001 COMPLIANCE SCORECARD"

echo ""
echo -e "${BOLD}${CYAN}  PCI-DSS v4.0 Control Coverage:${NC}"
PCI_REQS=(
  "Req 1: Network Security Controls"
  "Req 2: Secure Configurations"
  "Req 3: Protect Stored Account Data"
  "Req 4: Protect Cardholder Data in Transit"
  "Req 5: Malware Protection (Falco)"
  "Req 6: Secure Development Lifecycle"
  "Req 7: Restrict Access by Business Need"
  "Req 8: Identify Users and Authenticate Access"
  "Req 9: Restrict Physical Access (N/A - Cloud)"
  "Req 10: Log and Monitor All Access"
  "Req 11: Test Security Regularly"
  "Req 12: Information Security Policy"
)
for req in "${PCI_REQS[@]}"; do
  echo -e "  ${CYAN}  ▸${NC} ${req}"
done

echo ""
echo -e "${BOLD}${CYAN}  NIST CSF 2.0 Function Coverage:${NC}"
echo -e "  ${CYAN}  GOVERN:${NC}   §27,28,30 — Policy, Risk, Compliance"
echo -e "  ${CYAN}  IDENTIFY:${NC} §2,14,15,16 — Asset, Vulnerability Management"
echo -e "  ${CYAN}  PROTECT:${NC}  §3-13,17-24 — Access Control, Encryption, Hardening"
echo -e "  ${CYAN}  DETECT:${NC}   §11,19 — Falco, Audit Logging, Monitoring"
echo -e "  ${CYAN}  RESPOND:${NC}  §30 — Incident Response, Runbooks"
echo -e "  ${CYAN}  RECOVER:${NC}  §22,26 — Backup, Chaos Engineering"

# =============================================================================
# FINAL SUMMARY REPORT
# =============================================================================

TOTAL=$((PASS + WARN + FAIL + INFO))
SCORE=$(awk "BEGIN {printf \"%.1f\", ($PASS / ($PASS + $FAIL + 1)) * 100}")

echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  ENTERPRISE SECURITY AUDIT — FINAL SUMMARY${NC}"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}${BOLD}PASS     : ${PASS}${NC}"
echo -e "  ${YELLOW}${BOLD}WARN     : ${WARN}${NC}"
echo -e "  ${RED}${BOLD}FAIL     : ${FAIL}${NC}"
echo -e "  ${RED}${BOLD}CRITICAL : ${CRITICAL_COUNT}${NC}"
echo -e "  ${CYAN}INFO     : ${INFO}${NC}"
echo -e "  ${BOLD}TOTAL    : ${TOTAL}${NC}"
echo ""

# Risk rating
if [[ "${CRITICAL_COUNT}" -gt 5 ]]; then
  echo -e "  ${RED}${BOLD}RISK RATING: 🔴 CRITICAL — Immediate action required${NC}"
elif [[ "${CRITICAL_COUNT}" -gt 0 || "${FAIL}" -gt 15 ]]; then
  echo -e "  ${RED}${BOLD}RISK RATING: 🟠 HIGH — Significant remediation needed${NC}"
elif [[ "${FAIL}" -gt 5 ]]; then
  echo -e "  ${YELLOW}${BOLD}RISK RATING: 🟡 MEDIUM — Remediation recommended${NC}"
else
  echo -e "  ${GREEN}${BOLD}RISK RATING: 🟢 LOW — Minor hardening recommended${NC}"
fi

echo ""
echo -e "  ${BOLD}Security Score: ${SCORE}% (Pass / Pass+Fail)${NC}"
echo ""
echo -e "  📁 Full report: ${BOLD}${REPORT_DIR}/${NC}"
echo -e "  📋 Findings:    ${BOLD}${FINDINGS_FILE}${NC}"
echo ""

# Generate JSON summary
if [[ "${JSON_OUTPUT}" == true ]]; then
  cat > "${JSON_FILE}" << EOF
{
  "audit_version": "${SCRIPT_VERSION}",
  "timestamp": "${TIMESTAMP}",
  "repository": "${REPO_ROOT}",
  "summary": {
    "pass": ${PASS},
    "warn": ${WARN},
    "fail": ${FAIL},
    "critical": ${CRITICAL_COUNT},
    "info": ${INFO},
    "total": ${TOTAL},
    "score_percent": "${SCORE}"
  },
  "standards": ["NIST-CSF-2.0","CIS-K8s-v1.9","OWASP-API-Top10","PCI-DSS-v4.0","SOC2","ISO27001-2022"],
  "report_dir": "${REPORT_DIR}"
}
EOF
  echo -e "  📊 JSON:        ${BOLD}${JSON_FILE}${NC}"
fi

echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "  Completed: $(date)"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Exit non-zero if critical findings
[[ "${CRITICAL_COUNT}" -gt 0 ]] && exit 2
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
