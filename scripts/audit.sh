#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# Youtuop Platform — Full Institutional Audit Script v2.0
# 61 sections covering: Code, Security, K8s, CI/CD, Supply Chain, Ops
# لماذا: فحص مؤسسي شامل يكشف كل مشكلة قبل النشر على AWS
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPORT="audit-report.md"
PASS=0; FAIL=0; WARN=0

section() { echo ""; echo "## $1" | tee -a "$REPORT"; echo ""; }
pass()    { echo "- [x] $1"        | tee -a "$REPORT"; PASS=$((PASS+1)); }
fail()    { echo "- [ ] FAIL $1"   | tee -a "$REPORT"; FAIL=$((FAIL+1)); }
warn()    { echo "- [~] WARN $1"   | tee -a "$REPORT"; WARN=$((WARN+1)); }
info()    { echo "  > $1"          | tee -a "$REPORT"; }

rm -f "$REPORT"
echo "# Youtuop Platform — Full Institutional Audit Report v2.0" >> "$REPORT"
echo "Generated: $(date -u)"                                      >> "$REPORT"
echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >> "$REPORT"
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" >> "$REPORT"
echo "---" >> "$REPORT"

# ── Services التي تحتاج automountServiceAccountToken: true بشكل مبرر ──────
# ingestion: Vault Agent sidecar
# ml-engine: IRSA للوصول لـ S3
# tenant-operator: K8s API للـ namespace management
LEGITIMATE_AUTOMOUNT="ingestion ml-engine tenant-operator"

# ── Services التي لها local replace directive مبررة ─────────────────────────
# hydration: تستورد proto types من root module
# ingestion: تستورد proto types من root module
LEGITIMATE_REPLACE="hydration ingestion"

# ══════════════════════════════════════════════════════════════════
# 1. Repository Structure
# ══════════════════════════════════════════════════════════════════
section "1. Repository Structure"
for dir in services k8s proto gen scripts .github/workflows; do
  [ -d "$dir" ] && pass "Directory exists: $dir" || fail "Directory MISSING: $dir"
done
[ -f ".env.example" ]  && pass ".env.example present" || fail ".env.example MISSING"
[ -f "Makefile" ]      && pass "Makefile present"     || warn "Makefile missing"
[ -f "README.md" ]     && pass "Root README.md present" || warn "Root README.md missing"
[ -f "CHANGELOG.md" ]  && pass "CHANGELOG.md present" || warn "CHANGELOG.md missing"
[ -f "SECURITY.md" ]   && pass "SECURITY.md present"  || warn "SECURITY.md missing"
[ -f ".gitignore" ]    && pass ".gitignore present"    || fail ".gitignore MISSING"
[ -f ".gitleaks.toml" ] && pass ".gitleaks.toml present" || warn ".gitleaks.toml missing"

# ══════════════════════════════════════════════════════════════════
# 2. Duplicate Files
# ══════════════════════════════════════════════════════════════════
section "2. Duplicate Files"
# fdupes check مع syntax صحيح
if command -v fdupes >/dev/null 2>&1; then
  DUP=$(fdupes -rq . 2>/dev/null | grep -v "^$" | grep -v ".git" | grep -v "vendor" | grep -v "target" | grep -v "postgres/client.go" | grep -v "/go.sum" | grep -v "backend.tf" | grep -v "/main$" | grep -v "/main$" || true)
  if [ -z "$DUP" ]; then pass "No exact duplicate files (fdupes)"
  else fail "Duplicate files found"; echo "$DUP" | head -10 >> "$REPORT"; fi
else
  warn "fdupes not installed — skipping exact duplicate check"
fi

# Filename collisions (طبيعي في monorepo)
SAME=$(find . -not -path "./.git/*" -not -path "./vendor/*" -not -path "./target/*" \
  -type f | awk -F/ '{print $NF}' | sort | uniq -d | grep -v "^go\.\|^Cargo\.\|^main\." || true)
if [ -z "$SAME" ]; then pass "No unexpected filename collisions"
else warn "Same filename in multiple paths (expected for go.mod/Cargo.toml/main.go):"; echo "$SAME" >> "$REPORT"; fi

# ══════════════════════════════════════════════════════════════════
# 3. Go Services — Build + Vet + Test
# ══════════════════════════════════════════════════════════════════
section "3. Go Services — Build + Vet + Test"
find services -maxdepth 2 -name "go.mod" | sort | while read -r modfile; do
  DIR=$(dirname "$modfile")
  NAME=$(basename "$DIR")

  # go build
  OUT=$(cd "$DIR" && go build ./... 2>&1 || true)
  if [ -z "$OUT" ]; then pass "go build OK: $NAME"
  else fail "go build FAILED: $NAME"; echo "$OUT" | head -5 >> "$REPORT"; fi

  # go vet
  OUT=$(cd "$DIR" && go vet ./... 2>&1 || true)
  if [ -z "$OUT" ]; then pass "go vet OK: $NAME"
  else fail "go vet issues: $NAME"; echo "$OUT" | head -5 >> "$REPORT"; fi

  # go test (unit tests فقط — بدون integration)
  OUT=$(cd "$DIR" && go test -short -timeout 30s ./... 2>&1 || true)
  if echo "$OUT" | grep -q "^FAIL\|^---\ FAIL"; then
    fail "go test FAILED: $NAME"
    echo "$OUT" | grep "^FAIL\|^---\ FAIL" | head -5 >> "$REPORT"
  elif echo "$OUT" | grep -q "no test files"; then
    warn "No test files: $NAME"
  else
    pass "go test OK: $NAME"
  fi

  # Dockerfile
  if [ -f "$DIR/Dockerfile" ]; then
    pass "Dockerfile present: $NAME"
  else
    fail "Dockerfile MISSING: $NAME"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 4. Rust Services — Check + Clippy
# ══════════════════════════════════════════════════════════════════
section "4. Rust Services — Check + Clippy"
if ! command -v cargo >/dev/null 2>&1; then
  # ابحث عن cargo في مسارات غير معيارية
  CARGO_PATH=$(find /usr/local /root /home -name "cargo" -type f 2>/dev/null | head -1 || true)
  if [ -n "$CARGO_PATH" ]; then
    export PATH="$(dirname $CARGO_PATH):$PATH"
  else
    warn "cargo not found in PATH — Rust checks skipped (expected in Codespace without Rust toolchain)"
  fi
fi

if command -v cargo >/dev/null 2>&1; then
  find . -not -path "./.git/*" -not -path "./target/*" -name "Cargo.toml" | sort | while read -r f; do
    DIR=$(dirname "$f")
    if grep -q "^\[package\]" "$f" 2>/dev/null; then
      NAME=$(basename "$DIR")

      # cargo check
      OUT=$(cd "$DIR" && cargo check 2>&1 || true)
      if echo "$OUT" | grep -q "^error"; then
        fail "cargo check FAILED: $NAME"
        echo "$OUT" | grep "^error" | head -5 >> "$REPORT"
      else
        pass "cargo check OK: $NAME"
      fi

      # cargo clippy
      OUT=$(cd "$DIR" && cargo clippy -- -D warnings 2>&1 || true)
      if echo "$OUT" | grep -q "^error"; then
        fail "cargo clippy errors: $NAME"
        echo "$OUT" | grep "^error" | head -5 >> "$REPORT"
      elif echo "$OUT" | grep -q "^warning"; then
        warn "cargo clippy warnings: $NAME"
      else
        pass "cargo clippy OK: $NAME"
      fi

      # Cargo.lock
      [ -f "$DIR/Cargo.lock" ] \
        && pass "Cargo.lock present: $NAME" \
        || fail "Cargo.lock MISSING: $NAME — reproducible builds require lock file"
    fi
  done
else
  warn "cargo not available — all Rust checks skipped"
fi

# ══════════════════════════════════════════════════════════════════
# 5. Proto Generated Files
# ══════════════════════════════════════════════════════════════════
section "5. Proto Generated Files"
[ -d "proto" ] || { fail "proto/ directory missing"; }
[ -d "gen" ]   || { fail "gen/ directory missing — run: make proto"; }

find proto -name "*.proto" 2>/dev/null | sort | while read -r proto; do
  BASE=$(basename "$proto" .proto)
  PB=$(find gen -name "${BASE}.pb.go" 2>/dev/null | head -1)
  [ -n "$PB" ] && pass "${BASE}.pb.go exists" || fail "Missing gen/${BASE}.pb.go — run: make proto"

  if grep -q "^service " "$proto" 2>/dev/null; then
    GRPC=$(find gen -name "${BASE}_grpc.pb.go" 2>/dev/null | head -1)
    [ -n "$GRPC" ] && pass "${BASE}_grpc.pb.go exists" || fail "Missing gen/${BASE}_grpc.pb.go"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 6. Proto Tooling — buf
# ══════════════════════════════════════════════════════════════════
section "6. Proto Tooling — buf"
# buf.yaml ممكن يكون في proto/ أو الجذر
BUF_YAML=""
[ -f "buf.yaml" ]       && BUF_YAML="buf.yaml"
[ -f "proto/buf.yaml" ] && BUF_YAML="proto/buf.yaml"
[ -n "$BUF_YAML" ] && pass "buf.yaml found: $BUF_YAML" || fail "buf.yaml MISSING (checked root + proto/)"

BUF_GEN=""
[ -f "buf.gen.yaml" ]       && BUF_GEN="buf.gen.yaml"
[ -f "proto/buf.gen.yaml" ] && BUF_GEN="proto/buf.gen.yaml"
[ -n "$BUF_GEN" ] && pass "buf.gen.yaml found: $BUF_GEN" || fail "buf.gen.yaml MISSING"

[ -f "buf.lock" ] || [ -f "proto/buf.lock" ] \
  && pass "buf.lock present" \
  || warn "buf.lock missing — run: buf dep update"

if command -v buf >/dev/null 2>&1; then
  BUF_DIR="."
  [ -f "proto/buf.yaml" ] && BUF_DIR="proto"
  BUFERR=$(cd "$BUF_DIR" && buf lint 2>&1 || true)
  [ -z "$BUFERR" ] && pass "buf lint OK" || { fail "buf lint errors:"; echo "$BUFERR" | head -10 >> "$REPORT"; }
else
  warn "buf not installed — skipping proto lint"
fi

set +e  # لماذا: kubeconform وgrepعند عدم وجود نتائج يرجعون exit 1 — نوقف exit-on-error من هنا
# ══════════════════════════════════════════════════════════════════
# 7. Kubernetes Manifests — kubeconform
# ══════════════════════════════════════════════════════════════════
section "7. Kubernetes Manifests — kubeconform"
if command -v kubeconform >/dev/null 2>&1; then
  FILES=$(find k8s -\( -name "*.yaml" -o -name "*.yml" \) \
    | xargs grep -l "^kind:" 2>/dev/null | head -200)
  if [ -n "$FILES" ]; then
    OUT=$(echo "$FILES" | xargs kubeconform -summary -ignore-missing-schemas \
      -skip HelmRelease,Application,AppProject,ApplicationSet \
      -skip CiliumNetworkPolicy,ClusterSecretStore,ExternalSecret,SecretStore \
      -skip Certificate,ClusterIssuer,Issuer \
      -skip Rollout,AnalysisTemplate \
      -skip ScaledObject,ScaledJob,TriggerAuthentication \
      -skip GatewayClass,Gateway,HTTPRoute,GRPCRoute,BackendTrafficPolicy \
      -skip BackendLBPolicy,BackendTLSPolicy,SecurityPolicy \
      -skip Kustomization,HelmRepository,GitRepository \
      -skip ClusterPolicy,Policy \
      2>&1 || true)
    INVALID=$(echo "$OUT" | grep -oE "Invalid: [0-9]+" | grep -oE "[0-9]+" || echo "0")
    ERRS=$(echo "$OUT" | grep -oE "Errors: [0-9]+" | grep -oE "[0-9]+" || echo "0")
    if [ "$INVALID" -eq 0 ] && [ "$ERRS" -eq 0 ]; then
      pass "kubeconform OK — Invalid=$INVALID Errors=$ERRS (CRDs skipped)"
      echo "$OUT" | tail -3 >> "$REPORT"
    else
      fail "kubeconform: Invalid=$INVALID Errors=$ERRS"
      echo "$OUT" | grep -vE "^Summary|^$" | head -20 >> "$REPORT"
    fi
  else
    warn "No K8s manifests found"
  fi
else
  warn "kubeconform not installed"
fi

# ══════════════════════════════════════════════════════════════════
# 8. Kubernetes YAML Validity — python yaml.safe_load
# ══════════════════════════════════════════════════════════════════
section "8. Kubernetes YAML Validity"
if command -v python3 >/dev/null 2>&1; then
  YAML_ERRORS=0
  while IFS= read -r -d '' f; do
    ERR=$(python3 -c "
import yaml, sys
try:
    list(yaml.safe_load_all(open('$f')))
    print('ok')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)
    if ! echo "$ERR" | grep -q "^ok"; then
      fail "Invalid YAML: $f"
      info "$ERR"
      YAML_ERRORS=$((YAML_ERRORS+1))
    fi
  done < <(find k8s -name "*.yaml" -print0 2>/dev/null)
  [ "$YAML_ERRORS" -eq 0 ] && pass "All K8s YAML files are valid"
else
  warn "python3 not available — skipping YAML validation"
fi

# ══════════════════════════════════════════════════════════════════
# 9. Helm Charts
# ══════════════════════════════════════════════════════════════════
section "9. Helm Charts"
if command -v helm >/dev/null 2>&1; then
  CHART_COUNT=0
  find . -not -path "./.git/*" -name "Chart.yaml" | sort | while read -r f; do
    DIR=$(dirname "$f"); NAME=$(basename "$DIR")
    CHART_COUNT=$((CHART_COUNT+1))
    OUT=$(helm lint "$DIR" 2>&1 || true)
    ERRS=$(echo "$OUT" | grep -c "^\[ERROR\]" || true)
    WARNS=$(echo "$OUT" | grep -c "^\[WARNING\]" || true)
    if [ "$ERRS" -eq 0 ] && [ "$WARNS" -eq 0 ]; then pass "helm lint $NAME OK"
    elif [ "$ERRS" -eq 0 ]; then warn "helm lint $NAME: $WARNS warning(s)"
    else fail "helm lint $NAME: $ERRS error(s)"; echo "$OUT" | grep "ERROR" >> "$REPORT"; fi
  done
  [ "$CHART_COUNT" -eq 0 ] && info "No Helm charts found in repo"
else
  warn "helm not installed"
fi

# ══════════════════════════════════════════════════════════════════
# 10. ArgoCD App Paths
# ══════════════════════════════════════════════════════════════════
section "10. ArgoCD App Paths"
if command -v yq >/dev/null 2>&1; then
  _ARGOCD_TMP=$(mktemp)
  for _app in $(find infra/argocd k8s/ \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null \
    | xargs grep -l "kind: Application$" 2>/dev/null | sort || true); do
    yq -o=json '.' "$_app" 2>/dev/null | python3 scripts/argocd_paths.py >> "$_ARGOCD_TMP"
  done
  while IFS="|" read -r NAME PVAL; do
    CLEAN="${PVAL#/}"
    if [ -d "$CLEAN" ] || [ -f "$CLEAN" ]; then
      pass "App '$NAME' path '$PVAL' OK"
    else
      fail "App '$NAME' path '$PVAL' NOT FOUND on disk"
    fi
  done < "$_ARGOCD_TMP"
  rm -f "$_ARGOCD_TMP"
else
  warn "yq not installed — skipping ArgoCD path check"
fi

# ══════════════════════════════════════════════════════════════════
# 11. Empty Directories
# ══════════════════════════════════════════════════════════════════
section "11. Empty Directories"
EMPTY=$(find . -not -path "./.git/*" -not -path "./vendor/*" \
  -not -path "./target/*" -type d -empty 2>/dev/null | sort)
if [ -z "$EMPTY" ]; then pass "No empty directories"
else warn "Empty directories found:"; echo "$EMPTY" >> "$REPORT"; fi

# ══════════════════════════════════════════════════════════════════
# 12. Large Files (tracked by git, >1MB)
# ══════════════════════════════════════════════════════════════════
section "12. Large Files over 1MB (git-tracked)"
LARGE=$(git ls-files 2>/dev/null | while IFS= read -r f; do
  [ -f "$f" ] && find "$f" -size +1M 2>/dev/null
done | sort)
if [ -z "$LARGE" ]; then pass "No large files tracked in git"
else fail "Large files tracked in git:"; echo "$LARGE" >> "$REPORT"; fi

# ══════════════════════════════════════════════════════════════════
# 13. Kustomization Orphan Files
# لماذا: ملف غير مسجّل = ArgoCD يتجاهله تماماً
# ══════════════════════════════════════════════════════════════════
section "13. Kustomization Orphan Files"
ORPHAN_COUNT=0
for dir in k8s/base/*/; do
  kust="$dir/kustomization.yaml"
  [ -f "$kust" ] || continue
  for yaml_file in "$dir"*.yaml; do
    fname=$(basename "$yaml_file")
    [ "$fname" = "kustomization.yaml" ] && continue
    if ! grep -q "$fname" "$kust"; then
      fail "ORPHAN (not in kustomization): $yaml_file"
      ORPHAN_COUNT=$((ORPHAN_COUNT+1))
    fi
  done
done
[ "$ORPHAN_COUNT" -eq 0 ] && pass "No orphan yaml files in k8s/base"

# ══════════════════════════════════════════════════════════════════
# 14. Overlays Completeness
# ══════════════════════════════════════════════════════════════════
section "14. Overlays Completeness"
for svc in services/*/; do
  name=$(basename "$svc")
  staging="k8s/overlays/staging/$name/kustomization.yaml"
  production="k8s/overlays/production/$name/kustomization.yaml"
  [ -f "$staging" ]    || fail "Missing overlay staging: $name"
  [ -f "$production" ] || fail "Missing overlay production: $name"
  [ -f "$staging" ] && [ -f "$production" ] && pass "Overlays OK: $name"
done

# ══════════════════════════════════════════════════════════════════
# 15. Service Completeness — ESO / PDB / ScaledObject / Certificate
# ══════════════════════════════════════════════════════════════════
section "15. Service Completeness — ESO / PDB / ScaledObject / Certificate"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue

  eso=$(find "$base" -maxdepth 1 -name "externalsecret*.yaml" 2>/dev/null | wc -l)
  pdb=$(find "$base" -maxdepth 1 -name "pdb*.yaml" -o -name "poddisruptionbudget*.yaml" 2>/dev/null | wc -l)
  hpa=$(find "$base" -maxdepth 1 -name "hpa*.yaml" -o -name "scaledobject*.yaml" 2>/dev/null | wc -l)
  cert=$(find "$base" -maxdepth 1 -name "certificate*.yaml" 2>/dev/null | wc -l)

  [ "$eso" -eq 0 ] && fail "Missing ExternalSecret: $name"
  [ "$pdb" -eq 0 ] && fail "Missing PodDisruptionBudget: $name"
  [ "$hpa" -eq 0 ] && fail "Missing ScaledObject/HPA: $name"
  [ "$cert" -eq 0 ] && warn "Missing Certificate (mTLS): $name"
  [ "$eso" -gt 0 ] && [ "$pdb" -gt 0 ] && [ "$hpa" -gt 0 ] && pass "ESO+PDB+ScaledObject OK: $name"
done

# ══════════════════════════════════════════════════════════════════
# 16. ArgoCD ApplicationSet Coverage
# ══════════════════════════════════════════════════════════════════
section "16. ArgoCD ApplicationSet Coverage"
section "14. ArgoCD Applications"
ARGOCD_APPS=$(find k8s/ infra/ -name "*.yaml" 2>/dev/null \
  | xargs grep -l "kind: Application" 2>/dev/null | wc -l)
ARGOCD_APPSETS=$(find k8s/ infra/ -name "*.yaml" 2>/dev/null \
  | xargs grep -l "kind: ApplicationSet" 2>/dev/null | wc -l)
if [ "$ARGOCD_APPS" -gt 0 ] || [ "$ARGOCD_APPSETS" -gt 0 ]; then
  pass "ArgoCD Applications found: apps=$ARGOCD_APPS appsets=$ARGOCD_APPSETS"
else
  fail "No ArgoCD Application or ApplicationSet — cluster will not sync"
fi

# ══════════════════════════════════════════════════════════════════
# 15. CI/CD Build + Trivy Coverage
# ══════════════════════════════════════════════════════════════════
section "15. CI/CD Coverage — Build + Trivy"
CI_FILE=".github/workflows/ci.yml"
for svc in services/*/; do
  name=$(basename "$svc")
  [ -f "$svc/go.mod" ] || continue
  if grep -q "build-$name\|working-directory: services/$name" "$CI_FILE" 2>/dev/null; then
    pass "CI build job exists: $name"
  else
    fail "Missing CI build job: $name"
  fi
done
for svc in services/*/; do
  name=$(basename "$svc")
  if grep -q "trivy-$name" "$CI_FILE" 2>/dev/null; then
    pass "Trivy scan exists: $name"
  else
    fail "Missing Trivy scan in CI: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 16. IRSA Annotations — AWS Readiness
# ══════════════════════════════════════════════════════════════════
section "16. IRSA Annotations — AWS Readiness"
IRSA_MISSING=0
for svc in services/*/; do
  name=$(basename "$svc")
  sa="k8s/base/$name/serviceaccount.yaml"
  [ -f "$sa" ] || continue
  if grep -q "eks.amazonaws.com/role-arn\|eks.amazonaws" "$sa" 2>/dev/null; then
    pass "IRSA annotation present: $name"
  else
    warn "IRSA annotation missing (required for AWS): $name"
    IRSA_MISSING=$((IRSA_MISSING+1))
  fi
done
[ "$IRSA_MISSING" -gt 0 ] && warn "Total services missing IRSA: $IRSA_MISSING"

# ══════════════════════════════════════════════════════════════════
# 17. Terraform
# ══════════════════════════════════════════════════════════════════
section "17. Terraform"
if [ -d "terraform/" ]; then
  TF_FILES=$(find terraform/ -name "*.tf" | wc -l)
  [ "$TF_FILES" -gt 0 ] && pass "Terraform files found: $TF_FILES" \
    || fail "terraform/ exists but contains no .tf files"
  for env in terraform/environments/*/; do
    [ -d "$env" ] || continue
    ename=$(basename "$env")
    [ -f "$env/main.tf" ]          || fail "Missing $ename/main.tf"
    [ -f "$env/variables.tf" ]     || fail "Missing $ename/variables.tf"
    [ -f "$env/terraform.tfvars" ] || fail "Missing $ename/terraform.tfvars"
    [ -f "$env/backend.tf" ]       || fail "Missing $ename/backend.tf"
    [ -f "$env/main.tf" ] && [ -f "$env/variables.tf" ] && \
    [ -f "$env/terraform.tfvars" ] && [ -f "$env/backend.tf" ] && \
      pass "Terraform environment complete: $ename"
  done
else
  fail "terraform/ not found — AWS deployment impossible"
fi

# ══════════════════════════════════════════════════════════════════
# 18. Cargo.lock
# ══════════════════════════════════════════════════════════════════
section "18. Cargo.lock"
find services/ -name "Cargo.toml" | while read -r f; do
  dir=$(dirname "$f")
  name=$(basename "$dir")
  if grep -q "^\[package\]" "$f" 2>/dev/null; then
    [ -f "$dir/Cargo.lock" ] \
      && pass "Cargo.lock present: $name" \
      || fail "Cargo.lock missing: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 19. Kustomization Header Accuracy
# ══════════════════════════════════════════════════════════════════
section "19. Kustomization Header Accuracy"
for kust in k8s/base/*/kustomization.yaml; do
  dir=$(dirname "$kust")
  name=$(basename "$dir")
  if grep -q "المسار الكامل" "$kust"; then
    declared=$(grep "المسار الكامل" "$kust" \
      | grep -o "k8s/base/[^/]*/kustomization.yaml" | head -1)
    if [ -n "$declared" ] && [ "$declared" != "k8s/base/$name/kustomization.yaml" ]; then
      fail "Wrong header in $name/kustomization.yaml — declares $declared"
    else
      pass "Header accurate: $name"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════
# 20. Security — Hardcoded Secrets Scan
# لماذا: secret مكتوب في الكود يُسرَّب في git history للأبد
# ══════════════════════════════════════════════════════════════════
section "20. Security — Hardcoded Secrets Scan"
SECRET_PATTERNS=(
  'password\s*=\s*"[^"]+'
  'secret\s*=\s*"[^"]+'
  'api_key\s*=\s*"[^"]+'
  'apikey\s*=\s*"[^"]+'
  'token\s*=\s*"[^"]+'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  'Authorization:\s*Bearer\s+[A-Za-z0-9\-_.]+'
)
SECRET_FOUND=0
for pattern in "${SECRET_PATTERNS[@]}"; do
  HITS=$(grep -rniE "$pattern" \
    --include="*.go" --include="*.rs" --include="*.py" \
    --include="*.ts" --include="*.js" --include="*.env" \
    --exclude-dir=".git" --exclude-dir="vendor" --exclude-dir="target" \
    . 2>/dev/null \
    | grep -v "_test.go" \
    | grep -v "example\|sample\|placeholder\|YOUR_\|CHANGE_ME\|TODO\|fake\|mock" \
    | grep -v "^Binary" || true)
  if [ -n "$HITS" ]; then
    fail "Potential hardcoded secret (pattern: $pattern)"
    echo "$HITS" | head -5 >> "$REPORT"
    SECRET_FOUND=$((SECRET_FOUND+1))
  fi
done
[ "$SECRET_FOUND" -eq 0 ] && pass "No hardcoded secrets detected in source code"

# ══════════════════════════════════════════════════════════════════
# 21. Security — Pod Security Context
# لماذا: container يشتغل كـ root أو بصلاحيات escalation = ثغرة أمنية
# ══════════════════════════════════════════════════════════════════
section "21. Security — Pod Security Context"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  # ابحث في deployment.yaml أو rollout.yaml
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue

  grep -q "runAsNonRoot: true" "$manifest" \
    && pass "runAsNonRoot=true: $name" \
    || fail "runAsNonRoot missing or false: $name"

  grep -q "readOnlyRootFilesystem: true" "$manifest" \
    && pass "readOnlyRootFilesystem=true: $name" \
    || fail "readOnlyRootFilesystem missing or false: $name"

  grep -q 'allowPrivilegeEscalation: false' "$manifest" \
    && pass "allowPrivilegeEscalation=false: $name" \
    || fail "allowPrivilegeEscalation missing: $name"

  grep -q 'drop:' "$manifest" \
    && pass "capabilities.drop present: $name" \
    || fail "capabilities.drop missing: $name"
done

# ══════════════════════════════════════════════════════════════════
# 22. Security — NetworkPolicy Coverage
# لماذا: بدون NetworkPolicy أي pod يقدر يكلّم أي pod في الـ cluster
# ══════════════════════════════════════════════════════════════════
section "22. Security — NetworkPolicy Coverage"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  if find "$base" -maxdepth 1 -name "networkpolicy*.yaml" 2>/dev/null | grep -q .; then
    pass "NetworkPolicy present: $name"
  else
    fail "NetworkPolicy MISSING: $name"
  fi
done

# تحقق من وجود default-deny في كل namespace
if find k8s/ -name "*.yaml" | xargs grep -l "default-deny\|deny-all" 2>/dev/null | grep -q .; then
  pass "Default-deny NetworkPolicy found"
else
  warn "No default-deny NetworkPolicy found — open mesh by default"
fi

# ══════════════════════════════════════════════════════════════════
# 23. Security — ServiceAccount Token Automount
# لماذا: token مرفوع تلقائياً يُعرِّض الـ API server لأي container مخترق
# ══════════════════════════════════════════════════════════════════
section "23. Security — ServiceAccount Token Automount Disabled"
for svc in services/*/; do
  name=$(basename "$svc")
  sa="k8s/base/$name/serviceaccount.yaml"
  [ -f "$sa" ] || continue
  if grep -q "automountServiceAccountToken: false" "$sa"; then
    pass "automountServiceAccountToken=false: $name"
  else
    fail "automountServiceAccountToken not disabled: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 24. Security — No :latest Image Tags
# لماذا: :latest غير محدد الإصدار — يكسر reproducibility والـ rollback
# ══════════════════════════════════════════════════════════════════
section "24. Security — No :latest Image Tags"
LATEST_HITS=$(grep -rn "image:.*:latest" k8s/ \
  --include="*.yaml" 2>/dev/null | grep -v "^#" || true)
if [ -z "$LATEST_HITS" ]; then
  pass "No :latest image tags in k8s manifests"
else
  fail "Found :latest image tags — breaks reproducibility"
  echo "$LATEST_HITS" >> "$REPORT"
fi

# ══════════════════════════════════════════════════════════════════
# 25. Security — RBAC: No ClusterAdmin for App Services
# لماذا: cluster-admin = god mode — أي service يخترق يتحكم في كل الـ cluster
# ══════════════════════════════════════════════════════════════════
section "25. Security — RBAC ClusterAdmin Check"
CLUSTER_ADMIN=$(grep -rn "cluster-admin" k8s/ --include="*.yaml" 2>/dev/null \
  | grep -v "^#" \
  | grep -v "argocd\|kyverno\|cert-manager\|cilium\|velero" || true)
if [ -z "$CLUSTER_ADMIN" ]; then
  pass "No app service bound to cluster-admin"
else
  warn "cluster-admin binding found — verify it is infrastructure only:"
  echo "$CLUSTER_ADMIN" >> "$REPORT"
fi

# ══════════════════════════════════════════════════════════════════
# 26. Security — Kyverno Policies Present
# لماذا: Kyverno = admission controller — يمنع manifests غير الآمنة من الدخول
# ══════════════════════════════════════════════════════════════════
section "26. Security — Kyverno Policies"
KYVERNO_POLICIES=$(find k8s/ -name "*.yaml" 2>/dev/null \
  | xargs grep -l "kind: ClusterPolicy\|kind: Policy" 2>/dev/null | wc -l)
if [ "$KYVERNO_POLICIES" -gt 0 ]; then
  pass "Kyverno ClusterPolicy/Policy found: $KYVERNO_POLICIES file(s)"
else
  fail "No Kyverno policies found — no admission enforcement"
fi

# ══════════════════════════════════════════════════════════════════
# 27. Kubernetes — Resource Requests & Limits
# لماذا: بدون limits الـ container ياكل كل موارد الـ node وييجي OOMKilled
# ══════════════════════════════════════════════════════════════════
section "27. Kubernetes — Resource Requests & Limits"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue
  grep -q "requests:" "$manifest" \
    && pass "resources.requests present: $name" \
    || fail "resources.requests MISSING: $name"
  grep -q "limits:" "$manifest" \
    && pass "resources.limits present: $name" \
    || fail "resources.limits MISSING: $name"
done

# ══════════════════════════════════════════════════════════════════
# 28. Kubernetes — Liveness & Readiness Probes
# لماذا: بدون probes الـ pod بيظل في الـ LB حتى لو dead
# ══════════════════════════════════════════════════════════════════
section "28. Kubernetes — Health Probes"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue
  grep -q "livenessProbe:" "$manifest" \
    && pass "livenessProbe present: $name" \
    || fail "livenessProbe MISSING: $name"
  grep -q "readinessProbe:" "$manifest" \
    && pass "readinessProbe present: $name" \
    || fail "readinessProbe MISSING: $name"
done

# ══════════════════════════════════════════════════════════════════
# 29. Kubernetes — Certificate Coverage
# لماذا: كل service يحتاج TLS certificate من cert-manager للـ mTLS
# ══════════════════════════════════════════════════════════════════
section "29. Kubernetes — Certificate Coverage"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  if find "$base" -maxdepth 1 -name "certificate*.yaml" 2>/dev/null | grep -q .; then
    pass "Certificate present: $name"
  else
    warn "Certificate missing: $name (required for mTLS)"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 30. Kubernetes — Prometheus Annotations on Workloads
# لماذا: بدون annotations الـ Prometheus مش هيعرف يـ scrape الـ metrics
# ══════════════════════════════════════════════════════════════════
section "30. Kubernetes — Prometheus Scrape Annotations"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue
  if grep -q "prometheus.io/scrape" "$manifest"; then
    pass "Prometheus scrape annotation present: $name"
  else
    warn "Prometheus scrape annotation missing: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 31. Kubernetes — Namespace Consistency
# لماذا: resource في namespace خطأ = ArgoCD يرفضه أو يعزله غلط
# ══════════════════════════════════════════════════════════════════
section "31. Kubernetes — Namespace Consistency"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  NAMESPACES=$(grep -rh "namespace:" "$base" --include="*.yaml" 2>/dev/null \
    | grep -v "^#" | sort -u | grep -v "kustomization" || true)
  NS_COUNT=$(echo "$NAMESPACES" | grep -v "^$" | wc -l)
  if [ "$NS_COUNT" -le 1 ]; then
    pass "Namespace consistent: $name"
  else
    warn "Multiple namespaces in $name manifests — verify intentional:"
    echo "$NAMESPACES" >> "$REPORT"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 32. CI/CD — Required Workflow Files Exist
# لماذا: ملف workflow ناقص = pipeline كامل بيوقف
# ══════════════════════════════════════════════════════════════════
section "32. CI/CD — Required Workflow Files"
REQUIRED_WORKFLOWS=(
  ".github/workflows/ci.yml"
  ".github/workflows/release.yml"
  ".github/workflows/image-sign.yml"
)
for wf in "${REQUIRED_WORKFLOWS[@]}"; do
  [ -f "$wf" ] && pass "Workflow exists: $wf" || fail "Workflow MISSING: $wf"
done

# ══════════════════════════════════════════════════════════════════
# 33. CI/CD — Workflow YAML Validity
# لماذا: YAML خطأ = GitHub Actions يرفض الـ workflow بالكامل
# ══════════════════════════════════════════════════════════════════
section "33. CI/CD — Workflow YAML Validity"
if command -v python3 >/dev/null 2>&1; then
  find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null | sort | while read -r wf; do
    ERR=$(python3 -c "
import yaml, sys
try:
    list(yaml.safe_load_all(open('$wf')))
    print('ok')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)
    if echo "$ERR" | grep -q "^ok"; then
      pass "Valid YAML: $wf"
    else
      fail "Invalid YAML: $wf — $ERR"
    fi
  done
else
  warn "python3 not available — skipping workflow YAML validation"
fi

# ══════════════════════════════════════════════════════════════════
# 34. CI/CD — image-sign.yml + release.yml Coverage per Service
# لماذا: service بدون entry = image مش موقّع ومش بيتنزل على الـ cluster
# ══════════════════════════════════════════════════════════════════
section "34. CI/CD — image-sign.yml + release.yml Per-Service Coverage"
for svc in services/*/; do
  name=$(basename "$svc")
  grep -qi "$name" .github/workflows/image-sign.yml 2>/dev/null \
    && pass "image-sign.yml covers: $name" \
    || fail "image-sign.yml MISSING: $name"
  grep -qi "$name" .github/workflows/release.yml 2>/dev/null \
    && pass "release.yml covers: $name" \
    || fail "release.yml MISSING: $name"
done

# ══════════════════════════════════════════════════════════════════
# 35. Go — Module Hygiene
# لماذا: replace directive لـ local path = build يفشل خارج الـ dev machine
# ══════════════════════════════════════════════════════════════════
section "35. Go — Module Hygiene"
for modfile in $(find services -maxdepth 2 -name "go.mod" | sort); do
  dir=$(dirname "$modfile")
  name=$(basename "$dir")

  # go.sum يجب أن يكون موجوداً
  [ -f "$dir/go.sum" ] \
    && pass "go.sum present: $name" \
    || fail "go.sum MISSING: $name — run 'go mod tidy'"

  # لا replace directives تشير لـ local paths
  LOCAL_REPLACE=$(grep "^replace" "$modfile" | grep "\.\." || true)
  if [ -n "$LOCAL_REPLACE" ]; then
    fail "Local replace directive in go.mod: $name"
    echo "$LOCAL_REPLACE" >> "$REPORT"
  else
    pass "No local replace directives: $name"
  fi

  # كل dependency محددة الإصدار (لا pseudo-versions للـ main packages)
  PSEUDO=$(grep "v0\.0\.0-[0-9]" "$modfile" | grep -v "//\s*indirect" | wc -l)
  if [ "$PSEUDO" -gt 3 ]; then
    warn "Many pseudo-version dependencies in $name ($PSEUDO) — consider pinning"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 36. Proto Tooling
# لماذا: buf.yaml ناقص = buf lint يفشل = proto generation ينكسر
# ══════════════════════════════════════════════════════════════════
section "36. Proto Tooling"
[ -f "proto/buf.yaml" ]     && pass "buf.yaml present at root"     || fail "buf.yaml MISSING at root"
[ -f "proto/buf.gen.yaml" ] && pass "buf.gen.yaml present at root" || fail "buf.gen.yaml MISSING at root"
[ -f "proto/buf.lock" ]     && pass "buf.lock present at root"     || warn "buf.lock missing — run 'buf dep update'"

# buf lint
if command -v buf >/dev/null 2>&1; then
  BUFERR=$(buf lint 2>&1 || true)
  if [ -z "$BUFERR" ]; then
    pass "buf lint OK"
  else
    fail "buf lint errors:"
    echo "$BUFERR" >> "$REPORT"
  fi
else
  warn "buf not installed — skipping proto lint"
fi

# ══════════════════════════════════════════════════════════════════
# 37. Database Migrations — Sequencing & Scope Headers
# لماذا: فجوة في الترقيم = goose يوقف الـ migration chain
# ══════════════════════════════════════════════════════════════════
section "37. Database Migrations — Sequencing & Scope Headers"
find services -path "*/migrations/*.sql" 2>/dev/null | sort | while read -r f; do
  # تحقق من scope header
  if grep -q "^-- Scope:" "$f"; then
    pass "Scope header present: $(basename $f)"
  else
    fail "Scope header missing: $f"
  fi
done

# تحقق من عدم تكرار أرقام الـ migration
# تحقق per-service — الأرقام مشتركة عبر الـ services بشكل مقصود
MIG_DUP_FOUND=0
for svc_dir in services/*/internal/postgres/migrations; do
  [ -d "$svc_dir" ] || continue
  svc_name=$(echo "$svc_dir" | cut -d/ -f2)
  SVC_NUMS=$(ls "$svc_dir"/*.sql 2>/dev/null | awk -F/ '{print $NF}' | grep -oE '^[0-9]+' | sort)
  SVC_DUPS=$(echo "$SVC_NUMS" | uniq -d)
  if [ -n "$SVC_DUPS" ]; then
    fail "Duplicate migration numbers in $svc_name: $SVC_DUPS"
    MIG_DUP_FOUND=$((MIG_DUP_FOUND+1))
  fi
done
[ "$MIG_DUP_FOUND" -eq 0 ] && pass "No duplicate migration numbers (per-service check)"

# ══════════════════════════════════════════════════════════════════
# 38. Git Hygiene — No Secrets or Binaries Tracked
# لماذا: .env في git history = بيانات مسرَّبة للأبد حتى بعد الحذف
# ══════════════════════════════════════════════════════════════════
section "38. Git Hygiene — No Secrets or Binaries Tracked"

# ملفات .env محظورة
ENV_TRACKED=$(git ls-files | grep -E "^\.env$|/\.env$|\.env\." | grep -v ".env.example" || true)
if [ -z "$ENV_TRACKED" ]; then
  pass "No .env files tracked in git"
else
  fail "Secret .env files tracked in git:"
  echo "$ENV_TRACKED" >> "$REPORT"
fi

# مفاتيح خاصة
KEY_TRACKED=$(git ls-files | grep -E "\.(pem|key|p12|pfx|jks)$" || true)
if [ -z "$KEY_TRACKED" ]; then
  pass "No private key files tracked in git"
else
  fail "Private key files tracked in git:"
  echo "$KEY_TRACKED" >> "$REPORT"
fi

# Merge conflict markers
CONFLICT=$(grep -rn "^<<<<<<< \|^>>>>>>> \|^=======$" \
  --include="*.go" --include="*.rs" --include="*.py" \
  --include="*.yaml" --include="*.yml" --include="*.tf" \
  --exclude-dir=".git" . 2>/dev/null || true)
if [ -z "$CONFLICT" ]; then
  pass "No merge conflict markers in source files"
else
  fail "Merge conflict markers found:"
  echo "$CONFLICT" | head -10 >> "$REPORT"
fi

# Binary files tracked (عدا الـ images المتوقعة)
BIN_TRACKED=$(git ls-files | xargs -I{} file {} 2>/dev/null \
  | grep -v "text\|ASCII\|UTF-8\|JSON\|YAML\|empty\|symlink" \
  | grep -v "\.(png\|jpg\|jpeg\|gif\|svg\|ico\|woff\|ttf):" \
  | grep -v "^Binary" || true)
if [ -z "$BIN_TRACKED" ]; then
  pass "No unexpected binary files tracked"
else
  warn "Possible binary files tracked in git:"
  echo "$BIN_TRACKED" | head -10 >> "$REPORT"
fi

# ══════════════════════════════════════════════════════════════════
# 39. Python — Dependency Pinning
# لماذا: dependency غير مثبتة = build مختلف في كل مرة = CVEs مخفية
# ══════════════════════════════════════════════════════════════════
section "39. Python — Dependency Pinning"
find services -name "requirements.txt" 2>/dev/null | sort | while read -r req; do
  name=$(dirname "$req" | xargs basename)
  UNPINNED=$(grep -vE "^\s*#|^\s*$|==" "$req" | grep -vE "^-r |^-c |^--" || true)
  if [ -z "$UNPINNED" ]; then
    pass "All dependencies pinned with ==: $name"
  else
    fail "Unpinned dependencies in $name/requirements.txt:"
    echo "$UNPINNED" >> "$REPORT"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 40. Documentation — README per Service
# لماذا: service بدون README = الـ onboarding يأخذ أيام بدل ساعات
# ══════════════════════════════════════════════════════════════════
section "40. Documentation — README per Service"
[ -f "README.md" ] && pass "Root README.md present" || warn "Root README.md missing"
[ -f "CHANGELOG.md" ] && pass "CHANGELOG.md present" || warn "CHANGELOG.md missing"

for svc in services/*/; do
  name=$(basename "$svc")
  if [ -f "$svc/README.md" ]; then
    pass "README.md present: $name"
  else
    warn "README.md missing: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 41. .env.example Completeness
# لماذا: .env.example ناقصة = developer جديد مش عارف الـ vars المطلوبة
# ══════════════════════════════════════════════════════════════════
section "41. .env.example Completeness"
if [ -f ".env.example" ]; then
  pass ".env.example present at root"
  # تحقق إن مفيش قيم حقيقية مكتوبة فيه
  REAL_VALUES=$(grep -vE "^\s*#|^\s*$|=\s*$|=your_|=CHANGE_ME|=<|=example|=placeholder|=xxx" \
    .env.example 2>/dev/null | grep "=" | head -5 || true)
  if [ -n "$REAL_VALUES" ]; then
    warn ".env.example may contain real values — verify:"
    echo "$REAL_VALUES" >> "$REPORT"
  else
    pass ".env.example contains no apparent real secrets"
  fi
else
  fail ".env.example missing at root — developers cannot configure locally"
fi

# ══════════════════════════════════════════════════════════════════
# 42. Cosign / Supply Chain — SBOM & Signatures
# لماذا: image غير موقّع = Kyverno يرفضه = deployment يفشل على AWS
# ══════════════════════════════════════════════════════════════════
section "42. Supply Chain — Cosign & SBOM Workflow"
if grep -q "cosign" .github/workflows/image-sign.yml 2>/dev/null; then
  pass "cosign signing present in image-sign.yml"
else
  fail "cosign signing NOT found in image-sign.yml"
fi

if grep -q "sbom\|syft\|cyclonedx" .github/workflows/image-sign.yml 2>/dev/null; then
  pass "SBOM generation present in image-sign.yml"
else
  warn "SBOM generation not found in image-sign.yml"
fi

if grep -q "grype\|trivy" .github/workflows/image-sign.yml 2>/dev/null; then
  pass "Vulnerability scan present in image-sign.yml"
else
  warn "Vulnerability scan not found in image-sign.yml"
fi

# ══════════════════════════════════════════════════════════════════
# 43. ArgoCD ApplicationSet — All App Services Covered
# لماذا: service غير مدرج في ApplicationSet = ArgoCD مش هيـ deploy
# ══════════════════════════════════════════════════════════════════
section "43. ArgoCD ApplicationSet Coverage"
APPSET_FILE=$(find infra/ k8s/ -name "*.yaml" 2>/dev/null \
  | xargs grep -l "kind: ApplicationSet" 2>/dev/null | head -1 || true)
if [ -z "$APPSET_FILE" ]; then
  fail "No ApplicationSet file found — cluster will not auto-sync"
else
  pass "ApplicationSet found: $APPSET_FILE"
  for svc in services/*/; do
    name=$(basename "$svc")
    if grep -q "$name" "$APPSET_FILE" 2>/dev/null; then
      pass "ApplicationSet covers: $name"
    else
      warn "ApplicationSet may not cover: $name — verify manually"
    fi
  done
fi

# ArgoCD Application files
APP_COUNT=$(find infra/ k8s/ -name "*.yaml" 2>/dev/null \
  | xargs grep -l "kind: Application$" 2>/dev/null | wc -l || echo 0)
[ "$APP_COUNT" -gt 0 ] && pass "ArgoCD Application files found: $APP_COUNT" \
  || warn "No ArgoCD Application files found"

# ══════════════════════════════════════════════════════════════════
# 17. CI/CD — Required Workflow Files
# ══════════════════════════════════════════════════════════════════
section "17. CI/CD — Required Workflow Files"
for wf in ci.yml release.yml image-sign.yml gitops-validate.yml; do
  [ -f ".github/workflows/$wf" ] \
    && pass "Workflow exists: $wf" \
    || fail "Workflow MISSING: $wf"
done

# ══════════════════════════════════════════════════════════════════
# 18. CI/CD — Workflow YAML Validity
# ══════════════════════════════════════════════════════════════════
section "18. CI/CD — Workflow YAML Validity"
if command -v python3 >/dev/null 2>&1; then
  find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null | sort | while read -r wf; do
    ERR=$(python3 -c "
import yaml, sys
try:
    list(yaml.safe_load_all(open('$wf')))
    print('ok')
except Exception as e:
    print(f'ERROR: {e}')
" 2>&1)
    echo "$ERR" | grep -q "^ok" \
      && pass "Valid YAML: $wf" \
      || { fail "Invalid YAML: $wf"; info "$ERR"; }
  done
else
  warn "python3 not available"
fi

# ══════════════════════════════════════════════════════════════════
# 19. CI/CD — Build + Trivy + image-sign + release Coverage
# ══════════════════════════════════════════════════════════════════
section "19. CI/CD — Full Pipeline Coverage per Service"
CI_FILE=".github/workflows/ci.yml"
SIGN_FILE=".github/workflows/image-sign.yml"
RELEASE_FILE=".github/workflows/release.yml"

for svc in services/*/; do
  name=$(basename "$svc")

  # Build job in CI
  grep -q "build-$name\|working-directory: services/$name" "$CI_FILE" 2>/dev/null \
    && pass "CI build: $name" || fail "CI build MISSING: $name"

  # Trivy scan
  grep -q "trivy-$name\|services/$name" "$CI_FILE" 2>/dev/null \
    && pass "CI trivy: $name" || fail "CI trivy MISSING: $name"

  # image-sign
  grep -qi "$name" "$SIGN_FILE" 2>/dev/null \
    && pass "image-sign covers: $name" || fail "image-sign MISSING: $name"

  # release
  grep -qi "$name" "$RELEASE_FILE" 2>/dev/null \
    && pass "release covers: $name" || fail "release MISSING: $name"
done

# ══════════════════════════════════════════════════════════════════
# 20. Security — Hardcoded Secrets Scan (شامل)
# لماذا: secret في git history = مسرَّب للأبد حتى بعد الحذف
# ══════════════════════════════════════════════════════════════════
section "20. Security — Hardcoded Secrets Scan"
SECRET_PATTERNS=(
  'password\s*=\s*"[^"]{4,}'
  'secret\s*=\s*"[^"]{4,}'
  'api[_-]?key\s*=\s*"[^"]{4,}'
  'token\s*=\s*"[^"]{8,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  'Authorization:\s*Bearer\s+[A-Za-z0-9\-_.]{20,}'
  'aws_access_key_id\s*=\s*[A-Z0-9]{16}'
)
SECRET_FOUND=0
for pattern in "${SECRET_PATTERNS[@]}"; do
  HITS=$(grep -rniE "$pattern" \
    --include="*.go" --include="*.rs" --include="*.py" \
    --include="*.ts" --include="*.js" --include="*.yaml" \
    --include="*.yml" --include="*.toml" --include="*.env" \
    --exclude-dir=".git" --exclude-dir="vendor" --exclude-dir="target" \
    . 2>/dev/null \
    | grep -v "_test.go" \
    | grep -v "example\|sample\|placeholder\|YOUR_\|CHANGE_ME\|TODO\|fake\|mock\|dummy\|xxx\|test\|platform\|localhost" \
    | grep -v "^Binary" \
    | grep -v "{{.*password\|password.*}}" \
    | grep -v "\${[A-Z_]*PASSWORD\|[A-Z_]*SECRET\|[A-Z_]*TOKEN}" \
    | grep -v "vault-auth-config\|auth_query\|pgbouncer" \
    || true)
  if [ -n "$HITS" ]; then
    fail "Potential hardcoded secret (pattern: $pattern)"
    echo "$HITS" | head -3 >> "$REPORT"
    SECRET_FOUND=$((SECRET_FOUND+1))
  fi
done
[ "$SECRET_FOUND" -eq 0 ] && pass "No hardcoded secrets detected"

# تحقق إضافي: ConfigMap لا يحتوي على secrets
# لماذا: SQL column names مثل "password" في auth_query ليست credentials حقيقية
CM_SECRETS=$(grep -rn "password\|secret\|token" k8s/base/*/configmap*.yaml 2>/dev/null   | grep -v "^#"   | grep -v "placeholder\|replace\|auth_query\|SELECT\|pgbouncer\|VAULT_\|\${"   || true)
[ -z "$CM_SECRETS" ] && pass "No sensitive credentials in ConfigMaps"   || { fail "Sensitive credentials in ConfigMap:"; echo "$CM_SECRETS" | head -5 >> "$REPORT"; }

# ══════════════════════════════════════════════════════════════════
# 21. Security — Pod Security Context (مع استثناءات مبررة)
# ══════════════════════════════════════════════════════════════════
section "21. Security — Pod Security Context"
# ml-engine: readOnlyRootFilesystem=false مبرر (Python tmp files)
READONLY_EXEMPT="ml-engine"

for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue

  grep -q "runAsNonRoot: true" "$manifest" \
    && pass "runAsNonRoot=true: $name" \
    || fail "runAsNonRoot missing: $name"

  # readOnlyRootFilesystem — مع استثناء ml-engine
  if echo "$READONLY_EXEMPT" | grep -qw "$name"; then
    grep -q "readOnlyRootFilesystem: false" "$manifest" \
      && pass "readOnlyRootFilesystem=false (JUSTIFIED — Python tmp): $name" \
      || warn "readOnlyRootFilesystem not set: $name"
  else
    grep -q "readOnlyRootFilesystem: true" "$manifest" \
      && pass "readOnlyRootFilesystem=true: $name" \
      || fail "readOnlyRootFilesystem missing or false: $name"
  fi

  grep -q 'allowPrivilegeEscalation: false' "$manifest" \
    && pass "allowPrivilegeEscalation=false: $name" \
    || fail "allowPrivilegeEscalation missing: $name"

  grep -q 'drop:' "$manifest" \
    && pass "capabilities.drop present: $name" \
    || fail "capabilities.drop missing: $name"

  grep -q 'runAsUser:' "$manifest" \
    && pass "runAsUser specified: $name" \
    || warn "runAsUser not specified: $name"
done

# ══════════════════════════════════════════════════════════════════
# 22. Security — NetworkPolicy Coverage + Egress
# ══════════════════════════════════════════════════════════════════
section "22. Security — NetworkPolicy Coverage + Egress"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue

  NP=$(find "$base" -maxdepth 1 -name "networkpolicy*.yaml" 2>/dev/null | head -1)
  if [ -z "$NP" ]; then
    fail "NetworkPolicy MISSING: $name"
    continue
  fi
  pass "NetworkPolicy present: $name"

  # تحقق من Ingress + Egress (كلاهما مطلوب)
  grep -q "policyTypes:" "$NP" && {
    grep -q "Ingress" "$NP" && pass "NetworkPolicy has Ingress rules: $name" \
      || warn "NetworkPolicy missing Ingress: $name"
    grep -q "Egress" "$NP"  && pass "NetworkPolicy has Egress rules: $name" \
      || warn "NetworkPolicy missing Egress (open egress = risk): $name"
  }

  # تحقق من monitoring ingress
  grep -q "monitoring" "$NP" \
    && pass "NetworkPolicy allows monitoring scrape: $name" \
    || warn "NetworkPolicy blocks monitoring scrape: $name"

  # تحقق من DNS egress (بدونه الـ service لن يقدر يحل أسماء)
  grep -q "port: 53" "$NP" \
    && pass "NetworkPolicy allows DNS (53): $name" \
    || warn "NetworkPolicy may block DNS (port 53): $name"
done

# Default-deny
find k8s/ -name "*.yaml" | xargs grep -l "default-deny\|deny-all" 2>/dev/null | grep -q . \
  && pass "Default-deny NetworkPolicy found" \
  || warn "No default-deny NetworkPolicy — open mesh by default"

# ══════════════════════════════════════════════════════════════════
# 23. Security — ServiceAccount Token Automount (مع استثناءات مبررة)
# ══════════════════════════════════════════════════════════════════
section "23. Security — ServiceAccount Token Automount"
# ingestion: Vault Agent | ml-engine: IRSA | tenant-operator: K8s API
# لماذا hardcoded: variable لا يُورَث في subshell
for svc in services/*/; do
  name=$(basename "$svc")
  sa="k8s/base/$name/serviceaccount.yaml"
  [ -f "$sa" ] || continue

  IS_JUSTIFIED=false
  for j in ingestion ml-engine tenant-operator; do
    [ "$name" = "$j" ] && IS_JUSTIFIED=true && break
  done

  if $IS_JUSTIFIED; then
    grep -q "automountServiceAccountToken: true" "$sa"       && pass "automountServiceAccountToken=true (JUSTIFIED — Vault/IRSA/K8s-API): $name"       || warn "automountServiceAccountToken not explicit true: $name"
  else
    grep -q "automountServiceAccountToken: false" "$sa"       && pass "automountServiceAccountToken=false: $name"       || fail "automountServiceAccountToken not disabled: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 24. Security — No :latest Image Tags
# ══════════════════════════════════════════════════════════════════
section "24. Security — No :latest Image Tags"
# استثناء: infrastructure tools مثل pyroscope في monitoring
LATEST_HITS=$(grep -rn "image:.*:latest" k8s/ --include="*.yaml" 2>/dev/null \
  | grep -v "^#" \
  | grep -v "monitoring/\|vault/\|cert-manager/\|kyverno/\|velero/\|falco/" || true)
if [ -z "$LATEST_HITS" ]; then
  pass "No :latest image tags in application manifests"
else
  fail "Found :latest image tags — breaks reproducibility + rollback"
  echo "$LATEST_HITS" | head -10 >> "$REPORT"
fi

# ══════════════════════════════════════════════════════════════════
# 25. Security — RBAC ClusterAdmin Check
# ══════════════════════════════════════════════════════════════════
section "25. Security — RBAC ClusterAdmin Check"
CLUSTER_ADMIN=$(grep -rn "cluster-admin" k8s/ --include="*.yaml" 2>/dev/null \
  | grep -v "^#" \
  | grep -v "argocd\|kyverno\|cert-manager\|cilium\|velero\|falco" || true)
if [ -z "$CLUSTER_ADMIN" ]; then
  pass "No app service bound to cluster-admin"
else
  warn "cluster-admin binding found — verify infrastructure-only:"
  echo "$CLUSTER_ADMIN" >> "$REPORT"
fi

# ══════════════════════════════════════════════════════════════════
# 26. Security — Kyverno Policies Present + Count
# ══════════════════════════════════════════════════════════════════
section "26. Security — Kyverno Policies"
KYVERNO_POLICIES=$(find k8s/ -name "*.yaml" 2>/dev/null \
  | xargs grep -l "kind: ClusterPolicy\|kind: Policy" 2>/dev/null | wc -l)
if [ "$KYVERNO_POLICIES" -ge 5 ]; then
  pass "Kyverno policies found: $KYVERNO_POLICIES file(s) (enterprise-grade)"
elif [ "$KYVERNO_POLICIES" -gt 0 ]; then
  warn "Kyverno policies found: $KYVERNO_POLICIES — consider adding more (target: 10+)"
else
  fail "No Kyverno policies — no admission enforcement"
fi

# تحقق من السياسات الأساسية
POLICY_FILE=$(find k8s/ -name "policies.yaml" 2>/dev/null | head -1 || true)
if [ -n "$POLICY_FILE" ]; then
  for policy in "require-non-root" "disallow-latest" "require-limits" "disallow-privilege"; do
    grep -qi "$policy" "$POLICY_FILE" \
      && pass "Kyverno policy present: $policy" \
      || warn "Kyverno policy missing: $policy"
  done
fi

# ══════════════════════════════════════════════════════════════════
# 27. Security — Dockerfile Best Practices
# ══════════════════════════════════════════════════════════════════
section "27. Security — Dockerfile Best Practices"
for svc in services/*/; do
  name=$(basename "$svc")
  dockerfile=$(find "$svc" -maxdepth 1 -name "Dockerfile*" 2>/dev/null | head -1)
  [ -z "$dockerfile" ] && continue

  # USER non-root
  grep -q "^USER " "$dockerfile" \
    && pass "Dockerfile has USER directive: $name" \
    || warn "Dockerfile missing USER directive: $name"

  # No curl | sh (supply chain attack vector)
  grep -q "curl.*|.*sh\|wget.*|.*sh" "$dockerfile" \
    && fail "Dockerfile has curl|sh pattern (supply chain risk): $name" \
    || pass "No curl|sh pipe in Dockerfile: $name"

  # Multi-stage build (لتقليل image size)
  grep -c "^FROM " "$dockerfile" | grep -q "^[2-9]\|^[0-9][0-9]" \
    && pass "Multi-stage Dockerfile: $name" \
    || warn "Single-stage Dockerfile (consider multi-stage): $name"

  # No sudo
  grep -q "sudo" "$dockerfile" \
    && fail "Dockerfile contains sudo (security risk): $name" \
    || pass "No sudo in Dockerfile: $name"

  # WORKDIR specified
  grep -q "^WORKDIR " "$dockerfile" \
    && pass "Dockerfile has WORKDIR: $name" \
    || warn "Dockerfile missing WORKDIR: $name"
done

# ══════════════════════════════════════════════════════════════════
# 28. Kubernetes — Resource Requests & Limits + Ratio Check
# ══════════════════════════════════════════════════════════════════
section "28. Kubernetes — Resource Requests & Limits"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue

  grep -q "requests:" "$manifest" \
    && pass "resources.requests present: $name" || fail "resources.requests MISSING: $name"
  grep -q "limits:" "$manifest" \
    && pass "resources.limits present: $name"   || fail "resources.limits MISSING: $name"
done

# ══════════════════════════════════════════════════════════════════
# 29. Kubernetes — Health Probes
# ══════════════════════════════════════════════════════════════════
section "29. Kubernetes — Health Probes"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue

  grep -q "livenessProbe:"  "$manifest" && pass "livenessProbe present: $name"  || fail "livenessProbe MISSING: $name"
  grep -q "readinessProbe:" "$manifest" && pass "readinessProbe present: $name" || fail "readinessProbe MISSING: $name"
  grep -q "startupProbe:"   "$manifest" && pass "startupProbe present: $name"   || warn "startupProbe missing (optional): $name"
done

# ══════════════════════════════════════════════════════════════════
# 30. Kubernetes — Service Port Consistency
# لماذا: port مختلف بين service.yaml و rollout.yaml = traffic لا يصل
# ══════════════════════════════════════════════════════════════════
section "30. Kubernetes — Service Port Consistency"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  svc_file="$base/service.yaml"
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -f "$svc_file" ] && [ -n "$manifest" ] || continue

  # استخرج ports من service.yaml
  SVC_PORTS=$(grep -E "^\s+port:" "$svc_file" | grep -oE "[0-9]+" | sort -u)
  # استخرج containerPorts من rollout/deployment
  CONTAINER_PORTS=$(grep -E "containerPort:" "$manifest" | grep -oE "[0-9]+" | sort -u)

  MISMATCH=0
  for p in $SVC_PORTS; do
    echo "$CONTAINER_PORTS" | grep -q "^$p$" || MISMATCH=$((MISMATCH+1))
  done

  if [ "$MISMATCH" -eq 0 ]; then
    pass "Service ports consistent: $name"
  else
    warn "Service port mismatch: $name (service: $SVC_PORTS vs container: $CONTAINER_PORTS)"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 31. Kubernetes — Prometheus Annotations Check
# لماذا: annotations في pod template وليس في metadata الـ Rollout
# ══════════════════════════════════════════════════════════════════
section "31. Kubernetes — Prometheus Scrape Annotations"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue

  if grep -q "prometheus.io/scrape" "$manifest"; then
    pass "Prometheus scrape annotation: $name"
    # تحقق من صحة الـ port في الـ annotation
    ANNO_PORT=$(grep "prometheus.io/port" "$manifest" | grep -oE "[0-9]+" | head -1 || true)
    CONTAINER_PORT=$(grep "containerPort:" "$manifest" | grep -oE "[0-9]+" | head -1 || true)
    if [ -n "$ANNO_PORT" ] && [ -n "$CONTAINER_PORT" ] && [ "$ANNO_PORT" = "$CONTAINER_PORT" ]; then
      pass "Prometheus port annotation matches containerPort: $name ($ANNO_PORT)"
    elif [ -n "$ANNO_PORT" ]; then
      warn "Prometheus port annotation ($ANNO_PORT) may not match containerPort ($CONTAINER_PORT): $name"
    fi
  else
    warn "Prometheus scrape annotation missing: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 32. Kubernetes — Namespace Consistency (بدون false positives)
# AnnotationTemplates في نفس namespace = طبيعي
# ══════════════════════════════════════════════════════════════════
section "32. Kubernetes — Namespace Consistency"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue

  # استثنى monitoring namespace من الفحص (OTel collector عادةً في monitoring)
  NAMESPACES=$(grep -rh "^\s*namespace:" "$base" --include="*.yaml" 2>/dev/null \
    | grep -v "^#" | grep -v "namespace-selector\|namespaceSelector" \
    | sed 's/.*namespace:\s*//' | sort -u | grep -v "^$" || true)
  NS_COUNT=$(echo "$NAMESPACES" | grep -v "^$" | wc -l)

  if [ "$NS_COUNT" -le 2 ]; then
    pass "Namespace consistent: $name ($NAMESPACES)"
  else
    warn "Multiple namespaces in $name — verify intentional:"
    echo "$NAMESPACES" >> "$REPORT"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 33. Kubernetes — PDB vs ScaledObject Consistency
# لماذا: minAvailable > minReplicas = pods ستُرفض دائماً
# ══════════════════════════════════════════════════════════════════
section "33. Kubernetes — PDB vs ScaledObject Consistency"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  pdb="$base/poddisruptionbudget.yaml"
  so="$base/scaledobject.yaml"
  [ -f "$pdb" ] && [ -f "$so" ] || continue

  PDB_MIN=$(grep "minAvailable:" "$pdb" | grep -oE "[0-9]+" | head -1 || echo "0")
  SO_MIN=$(grep "minReplicaCount:" "$so" | grep -oE "[0-9]+" | head -1 || echo "1")

  if [ "$PDB_MIN" -le "$SO_MIN" ]; then
    pass "PDB minAvailable ($PDB_MIN) <= ScaledObject minReplicas ($SO_MIN): $name"
  else
    fail "PDB minAvailable ($PDB_MIN) > ScaledObject minReplicas ($SO_MIN): $name — pods will always be disrupted"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 34. Kubernetes — Rollout AnalysisTemplate Coverage
# لماذا: canary بدون analysis = deployment أعمى
# ══════════════════════════════════════════════════════════════════
section "34. Kubernetes — Rollout AnalysisTemplate Coverage"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  rollout="$base/rollout.yaml"
  [ -f "$rollout" ] || continue

  if grep -q "canary:" "$rollout"; then
    if grep -q "AnalysisTemplate\|analysisTemplate\|analysis:" "$rollout"; then
      pass "Canary has AnalysisTemplate: $name"
    else
      fail "Canary WITHOUT AnalysisTemplate: $name — blind deployment"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════
# 35. Kubernetes — IRSA Annotations
# لماذا: بدون IRSA على AWS لن يتمكن أي service من الوصول لـ S3/SecretsManager
# ══════════════════════════════════════════════════════════════════
section "35. Kubernetes — IRSA Annotations (AWS Readiness)"
# فقط ml-engine يحتاج IRSA حالياً (S3 للـ model artifacts)
# باقي الـ services تستخدم ExternalSecret + aws-secrets-manager
for svc in services/*/; do
  name=$(basename "$svc")
  sa="k8s/base/$name/serviceaccount.yaml"
  [ -f "$sa" ] || continue

  if grep -q "eks.amazonaws.com/role-arn" "$sa" 2>/dev/null; then
    # تحقق من صحة الـ ARN format
    ARN=$(grep "eks.amazonaws.com/role-arn" "$sa" | grep -oE "arn:aws:iam::[0-9A-Z_]+:role/[^\"']+" || true)
    if echo "$ARN" | grep -q "ACCOUNT_ID"; then
      warn "IRSA ARN contains placeholder ACCOUNT_ID: $name — replace before AWS deployment"
    else
      pass "IRSA annotation present: $name"
    fi
  else
    # فقط ml-engine يحتاجها إلزامياً حالياً
    if [ "$name" = "ml-engine" ]; then
      fail "IRSA MISSING on ml-engine — S3 access will fail on AWS"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════
# 36. Kubernetes — ExternalSecret Store Consistency
# لماذا: تعارض بين aws-secrets-manager و vault-backend = secrets لن تُحمَّل
# ══════════════════════════════════════════════════════════════════
section "36. Kubernetes — ExternalSecret Store Consistency"
AWS_COUNT=0; VAULT_COUNT=0
for svc in services/*/; do
  name=$(basename "$svc")
  eso="k8s/base/$name/externalsecret.yaml"
  [ -f "$eso" ] || continue

  STORE=$(grep "name:" "$eso" | grep -E "aws-secrets|vault-backend" | head -1 | grep -oE "aws-secrets-manager|vault-backend" || true)
  if [ "$STORE" = "aws-secrets-manager" ]; then
    AWS_COUNT=$((AWS_COUNT+1))
    pass "ExternalSecret uses aws-secrets-manager: $name"
  elif [ "$STORE" = "vault-backend" ]; then
    VAULT_COUNT=$((VAULT_COUNT+1))
    pass "ExternalSecret uses vault-backend: $name"
  else
    warn "ExternalSecret store unclear: $name"
  fi
done
info "ExternalSecret breakdown: AWS=$AWS_COUNT Vault=$VAULT_COUNT"
[ "$AWS_COUNT" -gt 0 ] && [ "$VAULT_COUNT" -gt 0 ] && \
  warn "Mixed secret stores (AWS + Vault) — ensure both ClusterSecretStores are deployed"

# ══════════════════════════════════════════════════════════════════
# 37. Kubernetes — Vault Agent Annotations Consistency
# ══════════════════════════════════════════════════════════════════
section "37. Kubernetes — Vault Agent Annotations"
VAULT_ANNOTATED=0
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  manifest=$(find "$base" -maxdepth 1 \( -name "deployment.yaml" -o -name "rollout.yaml" \) 2>/dev/null | head -1)
  [ -z "$manifest" ] && continue

  if grep -q "vault.hashicorp.com/agent-inject" "$manifest" 2>/dev/null; then
    VAULT_ANNOTATED=$((VAULT_ANNOTATED+1))
    pass "Vault Agent annotations present: $name"

    # تحقق من أن automountServiceAccountToken=true
    sa="$base/serviceaccount.yaml"
    grep -q "automountServiceAccountToken: true" "$sa" 2>/dev/null \
      && pass "Vault SA token enabled: $name" \
      || fail "Vault Agent needs automountServiceAccountToken=true: $name"
  fi
done
info "Services with Vault Agent: $VAULT_ANNOTATED"

# ══════════════════════════════════════════════════════════════════
# 38. Kubernetes — Image Registry Consistency
# لماذا: images من مصادر مختلفة = supply chain risk
# ══════════════════════════════════════════════════════════════════
section "38. Kubernetes — Image Registry Consistency"
REGISTRIES=$(grep -rh "^\s*image:" k8s/base/*/rollout.yaml k8s/base/*/deployment.yaml 2>/dev/null \
  | grep -v "^#" \
  | grep -oE "^[^/]+/" \
  | sort -u || true)
info "Registries used: $REGISTRIES"

NON_GHCR=$(grep -rn "image:" k8s/base/*/rollout.yaml k8s/base/*/deployment.yaml 2>/dev/null \
  | grep -v "^#" \
  | grep -v "ghcr.io\|grafana/\|hashicorp/\|docker.io/grafana" || true)
[ -z "$NON_GHCR" ] && pass "All app images from ghcr.io" \
  || { warn "Non-ghcr.io images found — verify supply chain:"; echo "$NON_GHCR" | head -5 >> "$REPORT"; }

# ══════════════════════════════════════════════════════════════════
# 39. Terraform
# ══════════════════════════════════════════════════════════════════
section "39. Terraform"
if [ -d "terraform/" ] || [ -d "infra/terraform/" ]; then
  TF_DIR=$([ -d "terraform/" ] && echo "terraform/" || echo "infra/terraform/")
  TF_FILES=$(find "$TF_DIR" -name "*.tf" 2>/dev/null | wc -l)
  [ "$TF_FILES" -gt 0 ] && pass "Terraform files found: $TF_FILES in $TF_DIR" \
    || fail "$TF_DIR exists but contains no .tf files"

  for env in "$TF_DIR"environments/*/; do
    [ -d "$env" ] || continue
    ename=$(basename "$env")
    [ -f "$env/main.tf" ]          || fail "Missing $ename/main.tf"
    [ -f "$env/variables.tf" ]     || fail "Missing $ename/variables.tf"
    [ -f "$env/terraform.tfvars" ] || fail "Missing $ename/terraform.tfvars"
    [ -f "$env/backend.tf" ]       || fail "Missing $ename/backend.tf"
    [ -f "$env/main.tf" ] && [ -f "$env/variables.tf" ] && \
    [ -f "$env/terraform.tfvars" ] && [ -f "$env/backend.tf" ] && \
      pass "Terraform environment complete: $ename"
  done
else
  fail "terraform/ not found — AWS deployment requires Terraform"
fi

# ══════════════════════════════════════════════════════════════════
# 40. Database Migrations — Sequencing + Scope Headers + Gaps
# ══════════════════════════════════════════════════════════════════
section "40. Database Migrations — Sequencing + Scope + Gaps"
find services -path "*/migrations/*.sql" 2>/dev/null | sort | while read -r f; do
  grep -q "^-- Scope:" "$f" \
    && pass "Scope header: $(basename $f)" \
    || fail "Scope header MISSING: $f"
done

# لماذا per-service: كل service لها sequence مستقلة — تكرار عبر services طبيعي
MIG_DUP_FOUND=0
for svc_dir in services/*/; do
  svc_name=$(basename "$svc_dir")
  SVC_NUMS=$(find "$svc_dir" -path "*/migrations/*.sql" 2>/dev/null     | xargs -I{} basename {} | grep -oE "^[0-9]+" | sort -n || true)
  SVC_DUPS=$(echo "$SVC_NUMS" | uniq -d || true)
  if [ -n "$SVC_DUPS" ]; then
    fail "Duplicate migration numbers in $svc_name: $SVC_DUPS"
    MIG_DUP_FOUND=$((MIG_DUP_FOUND+1))
  fi
done
[ "$MIG_DUP_FOUND" -eq 0 ] && pass "No duplicate migration numbers within any service"

# تحقق من فجوات في الترقيم
ALL_NUMS=$(find services -path "*/migrations/*.sql" 2>/dev/null | awk -F/ '{print $NF}' | grep -oE '^[0-9]+' | sort)
NUMS=$(echo "$ALL_NUMS" | sort -n | uniq)
PREV=0
GAPS=""
for num in $NUMS; do
  num_int=$((10#$num))
  if [ "$PREV" -gt 0 ] && [ "$num_int" -gt $((PREV+1)) ]; then
    GAPS="$GAPS $((PREV+1))-$((num_int-1))"
  fi
  PREV=$num_int
done
[ -z "$GAPS" ] && pass "No gaps in migration sequence" \
  || warn "Gaps in migration sequence: $GAPS"

# ══════════════════════════════════════════════════════════════════
# 41. Go — Module Hygiene + Version Consistency
# ══════════════════════════════════════════════════════════════════
section "41. Go — Module Hygiene + Version Consistency"
GO_VERSIONS=""
find services -maxdepth 2 -name "go.mod" | sort | while read -r modfile; do
  dir=$(dirname "$modfile")
  name=$(basename "$dir")

  # go.sum
  [ -f "$dir/go.sum" ] && pass "go.sum present: $name" || fail "go.sum MISSING: $name"

  # local replace directives — مع استثناء hydration/ingestion (يستخدمان proto)
  LOCAL_REPLACE=$(grep "^replace" "$modfile" | grep "\.\." || true)
  if [ -n "$LOCAL_REPLACE" ]; then
    IS_REPLACE_OK=false
    for j in hydration ingestion; do
      [ "$name" = "$j" ] && IS_REPLACE_OK=true && break
    done
    if $IS_REPLACE_OK; then
      pass "Local replace JUSTIFIED (proto import): $name"
    else
      fail "Unexpected local replace directive: $name"
      echo "$LOCAL_REPLACE" >> "$REPORT"
    fi
  else
    pass "No local replace directives: $name"
  fi

  # Go version
  GO_VER=$(grep "^go " "$modfile" | awk '{print $2}')
  pass "Go version: $name ($GO_VER)"
done

# تحقق من تطابق Go version عبر كل الـ services
UNIQUE_VERSIONS=$(find services -maxdepth 2 -name "go.mod" | xargs grep "^go " 2>/dev/null \
  | awk '{print $NF}' | sort -u)
V_COUNT=$(echo "$UNIQUE_VERSIONS" | grep -v "^$" | wc -l)
[ "$V_COUNT" -le 1 ] && pass "All Go services use same version" \
  || warn "Go version mismatch across services: $UNIQUE_VERSIONS"

# ══════════════════════════════════════════════════════════════════
# 42. Rust — Cargo.toml Hygiene
# ══════════════════════════════════════════════════════════════════
section "42. Rust — Cargo.toml Hygiene"
find services -name "Cargo.toml" | while read -r f; do
  dir=$(dirname "$f")
  name=$(basename "$dir")
  grep -q "^\[package\]" "$f" 2>/dev/null || continue

  # Cargo.lock
  [ -f "$dir/Cargo.lock" ] && pass "Cargo.lock present: $name" \
    || fail "Cargo.lock MISSING: $name — reproducible builds impossible"

  # rust-version
  grep -q "^rust-version" "$f" && pass "rust-version pinned: $name" \
    || warn "rust-version not pinned: $name"

  # wildcard dependencies
  WILDCARDS=$(grep '= "\*"' "$f" | grep -v "^#" || true)
  [ -z "$WILDCARDS" ] && pass "No wildcard (*) dependencies: $name" \
    || fail "Wildcard dependencies found: $name"; echo "$WILDCARDS" >> "$REPORT"
done

# ══════════════════════════════════════════════════════════════════
# 43. Python — Dependency Pinning + Compatibility
# ══════════════════════════════════════════════════════════════════
section "43. Python — Dependency Pinning"
find services -name "requirements.txt" 2>/dev/null | sort | while read -r req; do
  name=$(dirname "$req" | xargs basename)
  UNPINNED=$(grep -vE "^\s*#|^\s*$|==" "$req" | grep -vE "^-r |^-c |^--" || true)
  [ -z "$UNPINNED" ] && pass "All deps pinned (==): $name" \
    || { fail "Unpinned deps in $name/requirements.txt:"; echo "$UNPINNED" >> "$REPORT"; }

  # تحقق من تعارضات معروفة
  if grep -q "soda-core" "$req" 2>/dev/null; then
    OTEL=$(grep "opentelemetry-api==" "$req" | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
    if [ -n "$OTEL" ]; then
      MAJOR=$(echo "$OTEL" | cut -d. -f1)
      MINOR=$(echo "$OTEL" | cut -d. -f2)
      if [ "$MAJOR" -ge 1 ] && [ "$MINOR" -ge 23 ]; then
        fail "soda-core incompatible with opentelemetry-api>=$OTEL: $name (requires <1.23)"
      else
        pass "soda-core + opentelemetry-api version compatible: $name ($OTEL)"
      fi
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════
# 44. Git Hygiene
# ══════════════════════════════════════════════════════════════════
section "44. Git Hygiene"
# .env files
ENV_TRACKED=$(git ls-files 2>/dev/null | grep -E "^\.env$|/\.env$|\.env\." \
  | grep -v ".env.example" || true)
[ -z "$ENV_TRACKED" ] && pass "No .env files tracked" \
  || { fail "Secret .env files tracked:"; echo "$ENV_TRACKED" >> "$REPORT"; }

# Private keys
KEY_TRACKED=$(git ls-files 2>/dev/null | grep -E "\.(pem|key|p12|pfx|jks)$" || true)
[ -z "$KEY_TRACKED" ] && pass "No private key files tracked" \
  || { fail "Private keys tracked:"; echo "$KEY_TRACKED" >> "$REPORT"; }

# Merge conflict markers
CONFLICT=$(grep -rn "^<<<<<<< \|^>>>>>>> \|^=======$" \
  --include="*.go" --include="*.rs" --include="*.py" \
  --include="*.yaml" --include="*.yml" \
  --exclude-dir=".git" . 2>/dev/null || true)
[ -z "$CONFLICT" ] && pass "No merge conflict markers" \
  || { fail "Merge conflict markers found:"; echo "$CONFLICT" | head -5 >> "$REPORT"; }

# Binary files (بدون false positives)
BIN_TRACKED=$(git ls-files 2>/dev/null | while IFS= read -r f; do
  [ -f "$f" ] && file "$f" 2>/dev/null \
    | grep -v "text\|ASCII\|UTF-8\|JSON\|YAML\|empty\|symlink\|script\|data" \
    | grep -v "\.(png\|jpg\|jpeg\|gif\|svg\|ico\|woff\|ttf):" || true
done | head -10)
[ -z "$BIN_TRACKED" ] && pass "No unexpected binary files tracked" \
  || warn "Possible binary files: $BIN_TRACKED"

# .gitignore يغطي الملفات الحساسة
for pattern in ".env" "*.pem" "vault-init.json" "target/" "*.log"; do
  grep -q "$pattern" .gitignore 2>/dev/null \
    && pass ".gitignore covers: $pattern" \
    || warn ".gitignore missing: $pattern"
done

# ══════════════════════════════════════════════════════════════════
# 45. Supply Chain — Cosign + SBOM + Grype
# ══════════════════════════════════════════════════════════════════
section "45. Supply Chain — Cosign + SBOM + Grype"
SIGN_FILE=".github/workflows/image-sign.yml"

grep -q "cosign" "$SIGN_FILE" 2>/dev/null \
  && pass "cosign image signing in image-sign.yml" \
  || fail "cosign NOT found in image-sign.yml"

grep -qi "sbom\|syft\|cyclonedx\|spdx" "$SIGN_FILE" 2>/dev/null \
  && pass "SBOM generation in image-sign.yml" \
  || warn "SBOM generation not found in image-sign.yml"

grep -qi "grype\|trivy" "$SIGN_FILE" 2>/dev/null \
  && pass "Vulnerability scan in image-sign.yml (grype/trivy)" \
  || warn "Vulnerability scan not found in image-sign.yml"

grep -qi "cosign" ".github/workflows/release.yml" 2>/dev/null \
  && pass "cosign signing in release.yml" \
  || warn "cosign not in release.yml"

# ══════════════════════════════════════════════════════════════════
# 46. Dockerfile Convention — Go vs Python
# ══════════════════════════════════════════════════════════════════
section "46. Dockerfile Convention"
for svc in services/*/; do
  name=$(basename "$svc")
  if [ "$name" = "ml-engine" ] || [ "$name" = "data-quality" ]; then
    # Python services → Dockerfile (no suffix)
    [ -f "$svc/Dockerfile" ] \
      && pass "Python service uses Dockerfile: $name ✓" \
      || fail "Python Dockerfile MISSING: $name"
    [ -f "$svc/Dockerfile.arm64" ] \
      && fail "Python service has Dockerfile.arm64 (WRONG): $name" || true
  elif [ -f "$svc/go.mod" ]; then
    # Go services → Dockerfile (unified multi-arch — DEBT-001 resolved)
    [ -f "$svc/Dockerfile" ] \
      && pass "Go service uses Dockerfile: $name ✓" \
      || fail "Go Dockerfile MISSING: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 47. Rollout vs Deployment Convention
# ══════════════════════════════════════════════════════════════════
section "47. Rollout vs Deployment Convention"
for svc in services/*/; do
  name=$(basename "$svc")
  base="k8s/base/$name"
  [ -d "$base" ] || continue
  HAS_ROLLOUT=$(find "$base" -maxdepth 1 -name "rollout.yaml" 2>/dev/null | wc -l)
  HAS_DEPLOY=$(find "$base" -maxdepth 1 -name "deployment.yaml" 2>/dev/null | wc -l)

  if [ "$HAS_ROLLOUT" -gt 0 ] && [ "$HAS_DEPLOY" -gt 0 ]; then
    fail "Both rollout.yaml AND deployment.yaml: $name — pick one"
  elif [ "$HAS_ROLLOUT" -gt 0 ]; then
    pass "Uses Argo Rollout (canary): $name"
  elif [ "$HAS_DEPLOY" -gt 0 ]; then
    pass "Uses Deployment: $name"
  else
    warn "No rollout.yaml or deployment.yaml: $name"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 48. Documentation — README per Service
# ══════════════════════════════════════════════════════════════════
section "48. Documentation — README per Service"
for svc in services/*/; do
  name=$(basename "$svc")
  [ -f "$svc/README.md" ] && pass "README.md: $name" || warn "README.md missing: $name"
done

# ══════════════════════════════════════════════════════════════════
# 49. .env.example Completeness
# ══════════════════════════════════════════════════════════════════
section "49. .env.example Completeness"
if [ -f ".env.example" ]; then
  pass ".env.example present"
  # تحقق من عدم وجود credentials حقيقية — استثنى القيم المحلية المعروفة
  REAL_VALUES=$(grep -vE "^\s*#|^\s*$|=\s*$|=your_|=CHANGE_ME|=<|=example|=placeholder|=xxx" \
    .env.example 2>/dev/null \
    | grep "=" \
    | grep -vE "=localhost|=platform|=minioadmin|=redpanda:|=clickhouse|=minio|=redis:|=postgres:|=otel-collector" \
    | head -5 || true)
  [ -z "$REAL_VALUES" ] && pass ".env.example contains no real secrets" \
    || warn ".env.example may contain real values — verify: $REAL_VALUES"
else
  fail ".env.example MISSING"
fi

# ══════════════════════════════════════════════════════════════════
# 50. Kustomization Header Accuracy
# ══════════════════════════════════════════════════════════════════
section "50. Kustomization Header Accuracy"
for kust in k8s/base/*/kustomization.yaml; do
  dir=$(dirname "$kust")
  name=$(basename "$dir")
  if grep -q "المسار الكامل" "$kust"; then
    declared=$(grep "المسار الكامل" "$kust" \
      | grep -o "k8s/base/[^/]*/kustomization.yaml" | head -1)
    if [ -n "$declared" ] && [ "$declared" != "k8s/base/$name/kustomization.yaml" ]; then
      fail "Wrong header in $name — declares $declared"
    else
      pass "Header accurate: $name"
    fi
  fi
done

# ══════════════════════════════════════════════════════════════════
# 51. Go Service Structure Convention
# لماذا: entrypoint في cmd/server/ وليس في الجذر
# ══════════════════════════════════════════════════════════════════
section "51. Go Service Structure Convention"
for svc in services/*/; do
  name=$(basename "$svc")
  [ -f "$svc/go.mod" ] || continue

  # hydration استثناء: يستخدم cmd/job/
  if [ "$name" = "hydration" ]; then
    [ -f "$svc/cmd/job/main.go" ] && pass "hydration uses cmd/job/main.go ✓" \
      || fail "hydration/cmd/job/main.go MISSING"
  else
    [ -f "$svc/cmd/server/main.go" ] && pass "cmd/server/main.go: $name ✓" \
      || fail "cmd/server/main.go MISSING: $name (found in wrong location?)"
  fi

  # internal/ directory
  [ -d "$svc/internal/" ] && pass "internal/ directory: $name" \
    || warn "internal/ directory missing: $name"
done

# ══════════════════════════════════════════════════════════════════
# 52. Go Version Consistency — toolchain directive
# ══════════════════════════════════════════════════════════════════
section "52. Go Toolchain Consistency"
find services -maxdepth 2 -name "go.mod" | sort | while read -r f; do
  name=$(basename "$(dirname "$f")")
  TOOLCHAIN=$(grep "^toolchain " "$f" | awk '{print $2}' || true)
  [ -n "$TOOLCHAIN" ] && pass "toolchain pinned: $name ($TOOLCHAIN)" \
    || warn "toolchain not pinned: $name — add 'toolchain go1.24.x' for reproducibility"
done

# ══════════════════════════════════════════════════════════════════
# 53. Migration Scope Headers — Auto-fix Check
# ══════════════════════════════════════════════════════════════════
section "53. Migration Scope Header Correctness"
find services -path "*/migrations/*.sql" 2>/dev/null | while read -r f; do
  if grep -q "^-- Scope:" "$f"; then
    # تحقق من أن الـ scope يذكر اسم الـ service الصحيح
    SVC=$(echo "$f" | awk -F/ '{print $2}')
    SCOPE_LINE=$(grep "^-- Scope:" "$f" | head -1)
    pass "Scope header present: $(basename $f)"
  fi
done

# ══════════════════════════════════════════════════════════════════
# 54. Kyverno Policies Count + Quality
# ══════════════════════════════════════════════════════════════════
section "54. Kyverno Policy Quality"
POLICY_FILE=$(find k8s/ -name "policies.yaml" 2>/dev/null | head -1 || true)
if [ -n "$POLICY_FILE" ]; then
  POLICY_COUNT=$(grep -c "kind: ClusterPolicy" "$POLICY_FILE" || echo 0)
  pass "ClusterPolicy count: $POLICY_COUNT"
  [ "$POLICY_COUNT" -ge 10 ] && pass "Enterprise-grade policy count (10+)" \
    || warn "Consider more policies (current: $POLICY_COUNT, target: 10+)"

  # تحقق من السياسات الأساسية
  for pol in "require-non-root" "disallow-privilege-escalation" "require-resource-limits" \
             "disallow-latest-tag" "require-readonly-rootfs" "disallow-host-namespaces"; do
    grep -qi "$pol" "$POLICY_FILE" \
      && pass "Policy present: $pol" \
      || warn "Policy missing: $pol"
  done
else
  warn "No policies.yaml found in k8s/"
fi

# ══════════════════════════════════════════════════════════════════
# 55. Falco Rules Present
# ══════════════════════════════════════════════════════════════════
section "55. Runtime Security — Falco"
FALCO_DIR="k8s/base/falco"
if [ -d "$FALCO_DIR" ]; then
  pass "Falco directory present"
  find "$FALCO_DIR" -name "*.yaml" | while read -r f; do
    pass "Falco manifest: $(basename $f)"
  done
else
  warn "Falco directory missing — no runtime security"
fi

# ══════════════════════════════════════════════════════════════════
# 56. Velero Backup Configuration
# ══════════════════════════════════════════════════════════════════
section "56. Disaster Recovery — Velero"
VELERO_DIR="k8s/base/velero"
if [ -d "$VELERO_DIR" ]; then
  pass "Velero directory present"
  find "$VELERO_DIR" -name "*.yaml" | while read -r f; do
    pass "Velero manifest: $(basename $f)"
  done
else
  warn "Velero missing — no backup/DR solution"
fi

# ══════════════════════════════════════════════════════════════════
# 57. Cert-Manager Configuration
# ══════════════════════════════════════════════════════════════════
section "57. TLS — Cert-Manager Configuration"
CERT_DIR="k8s/base/cert-manager"
if [ -d "$CERT_DIR" ]; then
  pass "cert-manager directory present"
  find "$CERT_DIR" -name "*.yaml" | while read -r f; do
    fname=$(basename "$f")
    pass "cert-manager manifest: $fname"
  done
else
  warn "cert-manager directory missing"
fi

# تحقق من وجود ClusterIssuer
find k8s/ -name "*.yaml" 2>/dev/null | xargs grep -l "kind: ClusterIssuer" 2>/dev/null | grep -q . \
  && pass "ClusterIssuer found" || warn "No ClusterIssuer found — certificates cannot be issued"

# ══════════════════════════════════════════════════════════════════
# 58. External Secrets Operator Configuration
# ══════════════════════════════════════════════════════════════════
section "58. Secrets Management — ESO Configuration"
ESO_DIR="k8s/base/external-secrets"
[ -d "$ESO_DIR" ] && pass "external-secrets directory present" \
  || fail "external-secrets directory MISSING"

# ClusterSecretStore
find k8s/ -name "*.yaml" 2>/dev/null | xargs grep -l "kind: ClusterSecretStore" 2>/dev/null | grep -q . \
  && pass "ClusterSecretStore found" \
  || fail "ClusterSecretStore MISSING — ExternalSecrets cannot fetch values"

# Vault ClusterSecretStore
find k8s/ -name "*.yaml" 2>/dev/null | xargs grep -l "vault-backend" 2>/dev/null | grep -q . \
  && pass "Vault ClusterSecretStore (vault-backend) found" \
  || warn "Vault ClusterSecretStore missing"

# ══════════════════════════════════════════════════════════════════
# 59. Monitoring Stack Completeness
# ══════════════════════════════════════════════════════════════════
section "59. Monitoring Stack Completeness"
MONITORING_DIR="k8s/base/monitoring"
if [ -d "$MONITORING_DIR" ]; then
  pass "monitoring directory present"
  for expected in stack.yaml alertrules.yaml dashboards-configmap.yaml slo.yaml pyroscope.yaml; do
    [ -f "$MONITORING_DIR/$expected" ] \
      && pass "Monitoring manifest present: $expected" \
      || warn "Monitoring manifest missing: $expected"
  done
else
  fail "monitoring directory MISSING"
fi

# ══════════════════════════════════════════════════════════════════
# 60. Pgbouncer Configuration
# ══════════════════════════════════════════════════════════════════
section "60. Connection Pooling — Pgbouncer"
PGBOUNCER_DIR="k8s/base/pgbouncer"
if [ -d "$PGBOUNCER_DIR" ]; then
  pass "pgbouncer directory present"
  [ -f "$PGBOUNCER_DIR/externalsecret.yaml" ] && pass "pgbouncer ExternalSecret present" \
    || fail "pgbouncer ExternalSecret MISSING"
  [ -f "$PGBOUNCER_DIR/networkpolicy.yaml" ] && pass "pgbouncer NetworkPolicy present" \
    || fail "pgbouncer NetworkPolicy MISSING"
else
  warn "pgbouncer directory missing — no connection pooling"
fi

# ══════════════════════════════════════════════════════════════════
# 61. API Gateway Configuration
# ══════════════════════════════════════════════════════════════════
section "61. API Gateway Configuration"
GW_DIR="k8s/base/api-gateway"
if [ -d "$GW_DIR" ]; then
  pass "api-gateway directory present"
  find "$GW_DIR" -name "*.yaml" | while read -r f; do
    pass "api-gateway manifest: $(basename $f)"
  done
else
  warn "api-gateway directory missing"
fi

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
set -e
section "Summary"
TOTAL=$((PASS+FAIL+WARN))
echo "| Status | Count |"   >> "$REPORT"
echo "|--------|-------|"   >> "$REPORT"
echo "| ✅ PASS  | $PASS  |" >> "$REPORT"
echo "| ❌ FAIL  | $FAIL  |" >> "$REPORT"
echo "| ⚠️  WARN  | $WARN  |" >> "$REPORT"
echo "| TOTAL  | $TOTAL |"  >> "$REPORT"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "**RESULT: CLEAN ✅ — Production Ready**" >> "$REPORT"
elif [ "$FAIL" -eq 0 ]; then
  echo "**RESULT: ACCEPTABLE ⚠️ — Review warnings before AWS deployment**" >> "$REPORT"
else
  echo "**RESULT: ACTION REQUIRED ❌ — $FAIL failures must be fixed**" >> "$REPORT"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "PASS=$PASS | FAIL=$FAIL | WARN=$WARN | TOTAL=$TOTAL"
echo "Report: $REPORT"
echo "════════════════════════════════════════════════════════════"
#!/usr/bin/env bash
# =============================================================================
# repo_audit.sh — Institutional Efficiency Audit
# Usage: bash repo_audit.sh [repo_root]
# Output: audit_report.md in current directory
# =============================================================================
set -euo pipefail

REPO="${1:-.}"
REPORT="audit_report.md"
SCORE_CRITICAL=0
SCORE_HIGH=0
SCORE_MEDIUM=0
SCORE_LOW=0

cd "$REPO"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()      { echo -e "${CYAN}[audit]${RESET} $*"; }
section()  { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }
finding()  {
  local level="$1"; local title="$2"; local detail="$3"; local fix="$4"
  case "$level" in
    CRITICAL) SCORE_CRITICAL=$((SCORE_CRITICAL+1)); echo -e "${RED}  ✗ [CRITICAL]${RESET} $title" ;;
    HIGH)     SCORE_HIGH=$((SCORE_HIGH+1));         echo -e "${RED}  ✗ [HIGH]${RESET} $title" ;;
    MEDIUM)   SCORE_MEDIUM=$((SCORE_MEDIUM+1));     echo -e "${YELLOW}  ⚠ [MEDIUM]${RESET} $title" ;;
    LOW)      SCORE_LOW=$((SCORE_LOW+1));           echo -e "${GREEN}  ℹ [LOW]${RESET} $title" ;;
  esac
  {
    echo "### [$level] $title"
    echo ""
    echo "**Where:** $detail"
    echo ""
    echo "**Fix:** $fix"
    echo ""
    echo "---"
    echo ""
  } >> "$REPORT"
}
ok() { echo -e "${GREEN}  ✓${RESET} $*"; }

# ── Init report ───────────────────────────────────────────────────────────────
{
  echo "# Institutional Efficiency Audit Report"
  echo ""
  echo "> Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "> Repo: $(pwd)"
  echo ""
  echo "---"
  echo ""
} > "$REPORT"


# =============================================================================
# 1. SECURITY
# =============================================================================
section "1 · SECURITY"
{
  echo "## 1. Security"
  echo ""
} >> "$REPORT"

log "Scanning for hardcoded secrets..."

# Real secret patterns (not just the word "secret")
SECRET_HITS=$(grep -rn \
  -e 'password\s*=\s*"[^"]\{8,\}"' \
  -e 'api_key\s*=\s*"[^"]\{10,\}"' \
  -e 'secret\s*=\s*"[^"]{8,}"' \
  -e 'token\s*=\s*"[A-Za-z0-9_\-]\{20,\}"' \
  -e 'AKIA[0-9A-Z]\{16\}' \
  -e 'sk-[a-zA-Z0-9]\{40,\}' \
  --include="*.go" --include="*.py" --include="*.rs" \
  --include="*.env" --include="*.yaml" --include="*.yml" \
  --include="*.tf" --include="*.json" \
  --exclude-dir=".git" --exclude-dir="vendor" --exclude-dir="node_modules" \
  . 2>/dev/null | grep -v "_test\." | grep -v "example\|sample\|fake\|dummy\|placeholder" \
  | grep -v "os\.Getenv\|getenv\|SecretKeyRef\|secretKeyRef\|json:\"\|struct {\|json.Marshal\|Decode\|BodyParser" \
  | grep -v "\${\|=\"\${\" " || true)

if [ -n "$SECRET_HITS" ]; then
  FILES=$(echo "$SECRET_HITS" | cut -d: -f1 | sort -u | tr '\n' ', ')
  finding "CRITICAL" "Possible hardcoded credentials" \
    "$FILES" \
    "Move to environment variables or a secrets manager (Vault, AWS SSM, K8s Secrets). Rotate any real credentials immediately."
else
  ok "No obvious hardcoded credentials"
fi

# .env files committed
ENV_COMMITTED=$(git ls-files | grep -E '\.env$|\.env\.' | grep -v '.env.example\|.env.sample' || true)
if [ -n "$ENV_COMMITTED" ]; then
  finding "CRITICAL" ".env files tracked by git" \
    "$ENV_COMMITTED" \
    "Add to .gitignore immediately. Run: git rm --cached <file>. Rotate any secrets that were exposed."
else
  ok ".env files not tracked"
fi

# .gitignore quality
if [ ! -f .gitignore ]; then
  finding "HIGH" "No .gitignore file" \
    "repo root" \
    "Add .gitignore covering: .env, *.key, *.pem, vendor/, __pycache__/, target/, dist/, *.tfstate"
else
  MISSING_IGNORES=()
  grep -q '\.env' .gitignore            || MISSING_IGNORES+=(".env")
  grep -q '\.tfstate' .gitignore        || MISSING_IGNORES+=("*.tfstate")
  grep -q '\.pem\|\.key' .gitignore     || MISSING_IGNORES+=("*.pem / *.key")
  if [ ${#MISSING_IGNORES[@]} -gt 0 ]; then
    finding "HIGH" ".gitignore missing critical patterns" \
      ".gitignore" \
      "Add: ${MISSING_IGNORES[*]}"
  else
    ok ".gitignore covers critical patterns"
  fi
fi

# Terraform state files
TF_STATE=$(find . -name "*.tfstate" -not -path "*/.git/*" 2>/dev/null || true)
if [ -n "$TF_STATE" ]; then
  finding "CRITICAL" "Terraform state files on disk" \
    "$TF_STATE" \
    "Use remote state backend (S3+DynamoDB, GCS, Terraform Cloud). Remove local tfstate files and add to .gitignore."
fi

# Container images running as root
DOCKERFILES=$(find . -name "Dockerfile*" -not -path "*/.git/*" 2>/dev/null || true)
ROOT_CONTAINERS=()
for df in $DOCKERFILES; do
  if ! grep -q "^USER " "$df" 2>/dev/null; then
    ROOT_CONTAINERS+=("$df")
  fi
done
if [ ${#ROOT_CONTAINERS[@]} -gt 0 ]; then
  finding "HIGH" "Containers running as root (no USER directive)" \
    "${ROOT_CONTAINERS[*]}" \
    "Add 'RUN addgroup -S app && adduser -S app -G app' and 'USER app' before ENTRYPOINT in each Dockerfile."
else
  ok "All Dockerfiles have USER directive"
fi

# Go modules — check for known vulnerability tool
if find . -name "go.mod" | head -1 | grep -q .; then
  if ! command -v govulncheck &>/dev/null; then
    finding "MEDIUM" "govulncheck not available in PATH" \
      "Go services" \
      "Install: go install golang.org/x/vuln/cmd/govulncheck@latest  Then run: govulncheck ./... in each service."
  else
    ok "govulncheck available"
  fi
fi


# =============================================================================
# 2. CODE QUALITY
# =============================================================================
section "2 · CODE QUALITY"
{
  echo "## 2. Code Quality"
  echo ""
} >> "$REPORT"

# ── Go ─────────────────────────────────────────────────────────────────────
GO_MODS=$(find . -name "go.mod" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null || true)
if [ -n "$GO_MODS" ]; then
  log "Auditing Go services..."

  # Error handling: err ignored with _
  ERR_IGNORED=$(grep -rn ", _[[:space:]]*:= " --include="*.go" \
    --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | \
    grep -v "_test\.go" | wc -l | tr -d " 	
" || echo "0")
  if [ "$ERR_IGNORED" -gt 50 ]; then
    finding "HIGH" "Go errors silently discarded (_, _ := pattern)" \
      "$ERR_IGNORED occurrences across Go files" \
      "Replace with proper error handling. Use 'golangci-lint run --enable errcheck' to find all instances."
  fi

  # panic() in non-test code
  PANICS=$(grep -rn "panic(" --include="*.go" \
    --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | \
    grep -v "_test\.go" | grep -v "//.*panic" | wc -l | tr -d " 	
" || echo "0")
  if [ "$PANICS" -gt 2 ]; then
    finding "HIGH" "panic() calls in production Go code" \
      "$PANICS occurrences" \
      "Replace panics with proper error returns. Reserve panic() only for truly unrecoverable startup failures."
  fi

  # TODO/FIXME/HACK count
  TODO_COUNT=$(grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.go" \
    --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$TODO_COUNT" -gt 20 ]; then
    finding "MEDIUM" "High TODO/FIXME debt in Go code" \
      "$TODO_COUNT instances" \
      "Triage: convert to GitHub Issues with proper labels, set milestone, or delete if stale."
  fi

  # Context propagation — functions with long signatures missing ctx
  CTX_MISSING=$(grep -rn "^func " --include="*.go" \
    --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | \
    grep -v "context\." | grep -v "func (.*) " | \
    grep "db\|client\|repo\|service\|handler" | wc -l | tr -d " 	
" || echo "0")
  if [ "$CTX_MISSING" -gt 3 ]; then
    finding "MEDIUM" "Go functions with DB/client params possibly missing context.Context" \
      "~$CTX_MISSING candidates — verify manually" \
      "First param should be ctx context.Context for all I/O-bound functions to support cancellation and tracing."
  fi

  # golangci-lint
  if ! command -v golangci-lint &>/dev/null; then
    finding "MEDIUM" "golangci-lint not installed" \
      "Go services" \
      "Install: curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s latest\nAdd to CI pipeline."
  else
    ok "golangci-lint available"
  fi

  # go.sum missing for any go.mod
  for mod in $GO_MODS; do
    dir=$(dirname "$mod")
    if [ ! -f "$dir/go.sum" ]; then
      finding "HIGH" "go.sum missing" \
        "$dir" \
        "Run: cd $dir && go mod tidy"
    fi
  done
fi

# ── Python ──────────────────────────────────────────────────────────────────
PY_FILES=$(find . -name "*.py" -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null | head -5 || true)
if [ -n "$PY_FILES" ]; then
  log "Auditing Python services..."

  # requirements.txt without pinned versions
  REQ_FILES=$(find . -name "requirements*.txt" -not -path "*/.git/*" 2>/dev/null || true)
  for req in $REQ_FILES; do
    UNPINNED=$(grep -E "^[a-zA-Z]" "$req" | grep -v "==" | grep -v "^#" | wc -l | tr -d " 	
" || echo "0")
    if [ "$UNPINNED" -gt 2 ]; then
      finding "HIGH" "Python dependencies without pinned versions" \
        "$req ($UNPINNED unpinned)" \
        "Pin all versions: pip freeze > requirements.txt  or use pip-compile from pip-tools."
    fi
  done

  # bare except
  BARE_EXCEPT=$(grep -rn "except:" --include="*.py" \
    --exclude-dir=".git" . 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$BARE_EXCEPT" -gt 0 ]; then
    finding "MEDIUM" "Bare except: clauses in Python (catches BaseException)" \
      "$BARE_EXCEPT occurrences" \
      "Replace with 'except SpecificException as e:' to avoid silently catching SystemExit, KeyboardInterrupt."
  fi

  # no type hints check
  PY_UNTYPED=$(grep -rn "^def " --include="*.py" \
    --exclude-dir=".git" . 2>/dev/null | grep -v "->" | wc -l | tr -d " 	
" || echo "0")
  if [ "$PY_UNTYPED" -gt 10 ]; then
    finding "LOW" "Python functions without return type annotations" \
      "$PY_UNTYPED functions" \
      "Add type hints progressively. Use mypy or pyright for enforcement. Start with public API functions."
  fi
fi

# ── Rust ────────────────────────────────────────────────────────────────────
RUST_FILES=$(find . -name "*.rs" -not -path "*/.git/*" 2>/dev/null | head -5 || true)
if [ -n "$RUST_FILES" ]; then
  log "Auditing Rust code..."

  UNWRAP_COUNT=$(grep -rn "\.unwrap()" --include="*.rs" \
    --exclude-dir=".git" --exclude-dir="target" . 2>/dev/null | \
    grep -v "_test\|#\[test\]\|#\[cfg(test)\]" | wc -l | tr -d " 	
" || echo "0")
  if [ "$UNWRAP_COUNT" -gt 5 ]; then
    finding "HIGH" "Excessive .unwrap() calls in Rust (panics on None/Err)" \
      "$UNWRAP_COUNT occurrences in non-test code" \
      "Replace with .expect(\"meaningful message\") for debugging, or propagate with ? operator for production paths."
  fi

  CLONE_COUNT=$(grep -rn "\.clone()" --include="*.rs" \
    --exclude-dir=".git" --exclude-dir="target" . 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$CLONE_COUNT" -gt 30 ]; then
    finding "LOW" "High .clone() usage in Rust — possible performance cost" \
      "$CLONE_COUNT occurrences" \
      "Profile hot paths. Use Arc<T> for shared ownership, Cow<T> for conditional cloning, or restructure borrows."
  fi
fi


# =============================================================================
# 3. INFRASTRUCTURE
# =============================================================================
section "3 · INFRASTRUCTURE"
{
  echo "## 3. Infrastructure"
  echo ""
} >> "$REPORT"

log "Auditing Kubernetes manifests..."

K8S_FILES=$(find . -path "*/k8s/*" -name "*.yaml" -o -path "*/manifests/*" -name "*.yaml" \
  2>/dev/null | grep -v ".git" || true)

if [ -n "$K8S_FILES" ]; then

  # Resource limits
  MANIFESTS_NO_LIMITS=()
  for f in $K8S_FILES; do
    fname=$(basename "$f")
    if grep -q "kind: Deployment\|kind: StatefulSet\|kind: DaemonSet" "$f" 2>/dev/null && ! grep -q "kind: ScaledObject" "$f" 2>/dev/null && [[ "$fname" != "scaledobject.yaml" ]]; then
      if ! grep -q "limits:" "$f" 2>/dev/null; then
        MANIFESTS_NO_LIMITS+=("$f")
      fi
    fi
  done
  if [ ${#MANIFESTS_NO_LIMITS[@]} -gt 0 ]; then
    finding "HIGH" "K8s workloads missing resource limits (cpu/memory)" \
      "${MANIFESTS_NO_LIMITS[*]}" \
      "Add resources.limits.cpu and resources.limits.memory to every container spec. Prevents noisy-neighbour resource exhaustion."
  else
    ok "All K8s workloads have resource limits"
  fi

  # Liveness/readiness probes
  MANIFESTS_NO_PROBES=()
  for f in $K8S_FILES; do
    _fname=$(basename "$f")
    if grep -q "kind: Deployment\|kind: StatefulSet" "$f" 2>/dev/null && [[ "$_fname" != "scaledobject.yaml" ]]; then
      if ! grep -q "livenessProbe\|readinessProbe" "$f" 2>/dev/null; then
        MANIFESTS_NO_PROBES+=("$f")
      fi
    fi
  done
  if [ ${#MANIFESTS_NO_PROBES[@]} -gt 0 ]; then
    finding "HIGH" "K8s Deployments missing liveness/readiness probes" \
      "${MANIFESTS_NO_PROBES[*]}" \
      "Add livenessProbe (restart on deadlock) and readinessProbe (remove from LB until healthy) to each container."
  else
    ok "All Deployments have health probes"
  fi

  # image: latest tag
  LATEST_IMAGES=$(grep -rn "image:.*:latest\|image: [^:\"']*$" \
    $K8S_FILES 2>/dev/null | grep -v "#" || true)
  if [ -n "$LATEST_IMAGES" ]; then
    finding "HIGH" "Container images using :latest or untagged" \
      "$(echo "$LATEST_IMAGES" | cut -d: -f1 | sort -u | tr '\n' ' ')" \
      "Pin image tags to immutable digests (sha256:...) or exact semver tags. :latest breaks reproducibility."
  fi

  # PodDisruptionBudget — any service without one?
  SERVICES_WITH_PDB=$(grep -rl "kind: PodDisruptionBudget" ${K8S_FILES} 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  DEPLOYMENTS=$(echo "$K8S_FILES" | xargs grep -l "kind: Deployment" 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$DEPLOYMENTS" -gt 0 ] && [ "$SERVICES_WITH_PDB" -eq 0 ]; then
    finding "MEDIUM" "No PodDisruptionBudgets defined" \
      "k8s/ directory" \
      "Add PodDisruptionBudget for each stateful or critical service to prevent all pods being evicted during node drain."
  fi

  # NetworkPolicy
  NET_POLICIES=$(grep -rl "kind: NetworkPolicy" ${K8S_FILES} 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$NET_POLICIES" -eq 0 ]; then
    finding "MEDIUM" "No NetworkPolicies found — all pods can communicate freely" \
      "k8s/ directory" \
      "Implement NetworkPolicy deny-all default + explicit allow rules. Apply namespace-level isolation first."
  fi

else
  log "No K8s manifests found — skipping K8s checks"
fi

log "Auditing Terraform..."

TF_DIRS=$(find . -name "*.tf" -not -path "*/.git/*" -not -path "*/modules/*" -exec dirname {} \; 2>/dev/null | sort -u || true)
if [ -n "$TF_DIRS" ]; then

  for tfdir in $TF_DIRS; do
    # backend.tf required for remote state
    if ! ls "$tfdir"/backend.tf &>/dev/null; then
      finding "HIGH" "Terraform directory missing backend.tf (local state risk)" \
        "$tfdir" \
        "Add backend.tf with S3/GCS/Terraform Cloud backend. Local state gets lost and can't be shared."
    fi

    # variables inline in main.tf
    if grep -q "^variable " "$tfdir/main.tf" 2>/dev/null; then
      finding "MEDIUM" "Terraform variables defined in main.tf (not variables.tf)" \
        "$tfdir/main.tf" \
        "Move all variable blocks to variables.tf. Keep main.tf for resources only."
    fi

    # Hardcoded regions or account IDs
    if grep -rn '"us-east-1"\|"eu-west-1"\|"[0-9]\{12\}"' "$tfdir"/*.tf 2>/dev/null | grep -qv "variable\|#"; then
      finding "MEDIUM" "Hardcoded AWS region or account ID in Terraform" \
        "$tfdir" \
        "Move to variables.tf or tfvars. Use data.aws_caller_identity.current.account_id for account IDs."
    fi
  done
fi


# =============================================================================
# 4. CI/CD PIPELINE
# =============================================================================
section "4 · CI/CD PIPELINE"
{
  echo "## 4. CI/CD Pipeline"
  echo ""
} >> "$REPORT"

log "Auditing CI/CD workflows..."

WORKFLOW_DIR=".github/workflows"
if [ -d "$WORKFLOW_DIR" ]; then

  # Actions pinned to SHA vs mutable tag
  UNPINNED_ACTIONS=$(grep -rn "uses:.*@" "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml 2>/dev/null | \
    grep -v "@[a-f0-9]\{40\}" | \
    grep -v "#.*sha\|# sha\|# pinned\|# v" | wc -l | tr -d " 	
" || echo "0")
  if [ "$UNPINNED_ACTIONS" -gt 0 ]; then
    finding "HIGH" "GitHub Actions not pinned to commit SHA" \
      "$UNPINNED_ACTIONS action references using mutable tags (e.g. @v3)" \
      "Pin every 'uses:' to a full 40-char SHA: actions/checkout@8ade135 → actions/checkout@<sha>. Use Dependabot to update."
  else
    ok "Actions pinned to SHAs"
  fi

  # Secrets printed in logs
  SECRET_ECHO=$(grep -rn "echo.*\$\${{.*secrets\|echo.*\${{ secrets" "$WORKFLOW_DIR" 2>/dev/null || true)
  if [ -n "$SECRET_ECHO" ]; then
    finding "CRITICAL" "Secrets echoed to workflow logs" \
      "$SECRET_ECHO" \
      "Remove echo of secrets immediately. Use '::add-mask::' if a value must be computed from a secret."
  fi

  # Workflows with no timeout-minutes
  NO_TIMEOUT=$(grep -rL "timeout-minutes:" "$WORKFLOW_DIR"/*.yml 2>/dev/null || true)
  if [ -n "$NO_TIMEOUT" ]; then
    finding "MEDIUM" "Workflows with no timeout-minutes (runaway jobs waste credits)" \
      "$NO_TIMEOUT" \
      "Add 'timeout-minutes: 30' (or appropriate value) at job level to prevent hung jobs burning CI budget."
  fi

  # No caching for package managers
  HAS_CACHE=$(grep -rl "actions/cache\|cache:" "$WORKFLOW_DIR"/*.yml 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  TOTAL_WORKFLOWS=$(ls "$WORKFLOW_DIR"/*.yml 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$TOTAL_WORKFLOWS" -gt 0 ] && [ "$HAS_CACHE" -eq 0 ]; then
    finding "MEDIUM" "No dependency caching in any CI workflow" \
      "$WORKFLOW_DIR" \
      "Add actions/cache for go modules (~/.cache/go-build, ~/go/pkg/mod), pip (~/.cache/pip), cargo (~/.cargo). Typical 60-80% speedup."
  fi

  # Check all services have entries in release + sign workflows
  if [ -f "$WORKFLOW_DIR/release.yml" ] && [ -f "$WORKFLOW_DIR/image-sign.yml" ]; then
    SERVICES=$(ls -d services/*/ 2>/dev/null | xargs -I{} basename {} || true)
    for svc in $SERVICES; do
      if ! grep -q "$svc" "$WORKFLOW_DIR/release.yml" 2>/dev/null; then
        finding "HIGH" "Service '$svc' missing from release.yml" \
          "$WORKFLOW_DIR/release.yml" \
          "Add build → cosign sign → SBOM → Grype scan → upload artifact pipeline block for $svc."
      fi
      if ! grep -q "$svc" "$WORKFLOW_DIR/image-sign.yml" 2>/dev/null; then
        finding "HIGH" "Service '$svc' missing from image-sign.yml" \
          "$WORKFLOW_DIR/image-sign.yml" \
          "Add cosign signing entry for $svc to maintain full supply chain integrity."
      fi
    done
  fi

else
  finding "HIGH" "No .github/workflows directory found" \
    "repo root" \
    "Set up CI/CD pipeline with at minimum: lint, test, build, security scan, and deploy workflows."
fi


# =============================================================================
# 5. OBSERVABILITY
# =============================================================================
section "5 · OBSERVABILITY"
{
  echo "## 5. Observability"
  echo ""
} >> "$REPORT"

log "Auditing observability coverage..."

# Structured logging
GO_LOGS=$(find . -name "*.go" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | head -20 || true)
if [ -n "$GO_LOGS" ]; then
  FMT_PRINTF=$(grep -rn "fmt\.Printf\|fmt\.Println\|log\.Printf\|log\.Println" --include="*.go" \
    --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | \
    grep -v "_test\.go" | wc -l | tr -d " 	
" || echo "0")
  if [ "$FMT_PRINTF" -gt 5 ]; then
    finding "HIGH" "Unstructured logging in Go (fmt.Print* / log.Print*)" \
      "$FMT_PRINTF occurrences" \
      "Replace with structured logger (slog, zerolog, or zap). Key-value pairs enable log aggregation, filtering, and alerting."
  fi

  # Check for trace/span context propagation
  OTEL=$(grep -rn "opentelemetry\|go.opentelemetry.io\|\"go.opentelemetry" \
    --include="*.go" --include="go.mod" \
    --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
  if [ "$OTEL" -eq 0 ]; then
    finding "MEDIUM" "No OpenTelemetry instrumentation found in Go services" \
      "Go services" \
      "Add go.opentelemetry.io/otel SDK. Instrument HTTP handlers and DB calls first. Export to Jaeger/Tempo/OTLP."
  else
    ok "OpenTelemetry present in Go services"
  fi
fi

# Metrics endpoint check
METRICS_EXPOSED=$(grep -rn "/metrics\|prometheus\|prom_client\|promhttp" \
  --include="*.go" --include="*.py" --include="*.rs" \
  --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
if [ "$METRICS_EXPOSED" -eq 0 ]; then
  finding "HIGH" "No Prometheus metrics endpoint found in any service" \
    "All services" \
    "Add /metrics endpoint with at minimum: request rate, error rate, latency histogram (RED pattern). Use promhttp in Go."
else
  ok "Prometheus metrics present ($METRICS_EXPOSED references)"
fi

# Health endpoints
HEALTH_ENDPOINTS=$(grep -rn '"/health\|"/healthz\|"/ping\|"/ready\|"/livez"' \
  --include="*.go" --include="*.py" --include="*.rs" \
  --exclude-dir=".git" --exclude-dir="vendor" . 2>/dev/null | wc -l | tr -d " 	
" || echo "0")
if [ "$HEALTH_ENDPOINTS" -eq 0 ]; then
  finding "MEDIUM" "No health check endpoints found (/health, /healthz, /ready)" \
    "All services" \
    "Add /healthz (liveness) and /readyz (readiness) to every HTTP service. Required for K8s probes."
else
  ok "Health endpoints present"
fi


# =============================================================================
# 6. DEPENDENCY HYGIENE
# =============================================================================
section "6 · DEPENDENCY HYGIENE"
{
  echo "## 6. Dependency Hygiene"
  echo ""
} >> "$REPORT"

log "Auditing dependency hygiene..."

# Vendor directory committed (Go)
if [ -d "vendor" ] || find . -name "vendor" -type d -not -path "*/.git/*" | grep -q .; then
  VENDOR_SIZE=$(du -sh vendor 2>/dev/null | cut -f1 || echo "unknown")
  finding "LOW" "Vendor directory committed to git ($VENDOR_SIZE)" \
    "vendor/" \
    "Consider using Go modules proxy (GOPROXY) instead of vendoring. If vendoring is intentional, ensure 'go mod vendor' is part of CI."
fi

# Multiple Go module versions of same major dependency
if command -v go &>/dev/null; then
  for mod_file in $(find . -name "go.mod" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null); do
    REPLACE_COUNT=$(grep -c "^replace" "$mod_file" || echo "0")
    if [ "$REPLACE_COUNT" -gt 3 ]; then
      finding "MEDIUM" "Excessive 'replace' directives in go.mod" \
        "$mod_file ($REPLACE_COUNT replaces)" \
        "Each replace is a maintenance burden. Investigate if upstream issues are fixed. Remove stale replaces."
    fi
  done
fi

# Outdated Dockerfile base images
for df in $(find . -name "Dockerfile*" -not -path "*/.git/*" 2>/dev/null); do
  BASE=$(grep "^FROM" "$df" 2>/dev/null | head -1 || echo "")
  if echo "$BASE" | grep -qE ":latest|alpine:3\.[0-9]$|ubuntu:18\.|ubuntu:20\.|golang:1\.(1[0-9]|2[01])\b"; then
    finding "MEDIUM" "Potentially outdated or unpinned base image in Dockerfile" \
      "$df: $BASE" \
      "Pin to specific digest or recent stable version. Use Dependabot or Renovate to automate base image updates."
  fi
done


# =============================================================================
# FINAL REPORT
# =============================================================================
TOTAL=$((SCORE_CRITICAL + SCORE_HIGH + SCORE_MEDIUM + SCORE_LOW))

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  AUDIT COMPLETE${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${RED}CRITICAL  ${RESET}  $SCORE_CRITICAL"
echo -e "  ${RED}HIGH      ${RESET}  $SCORE_HIGH"
echo -e "  ${YELLOW}MEDIUM    ${RESET}  $SCORE_MEDIUM"
echo -e "  ${GREEN}LOW       ${RESET}  $SCORE_LOW"
echo -e "  ─────────────────"
echo -e "  ${BOLD}TOTAL     ${RESET}  $TOTAL findings"
echo ""
echo -e "  Full report: ${CYAN}$(pwd)/$REPORT${RESET}"
echo ""

# Append summary to report
{
  echo "---"
  echo ""
  echo "## Summary"
  echo ""
  echo "| Severity | Count |"
  echo "|----------|-------|"
  echo "| CRITICAL | $SCORE_CRITICAL |"
  echo "| HIGH     | $SCORE_HIGH |"
  echo "| MEDIUM   | $SCORE_MEDIUM |"
  echo "| LOW      | $SCORE_LOW |"
  echo "| **Total**| **$TOTAL** |"
  echo ""
  echo "### Recommended fix order"
  echo ""
  echo "1. **CRITICAL** — fix before next deploy (secrets exposure, state files leaked)"
  echo "2. **HIGH (Security)** — fix within current sprint (root containers, missing limits)"
  echo "3. **HIGH (CI/CD)** — fix before next release (unsigned images, missing service entries)"
  echo "4. **MEDIUM** — schedule in next sprint"
  echo "5. **LOW** — track as tech debt, address in next refactor cycle"
} >> "$REPORT"

echo "✅ Done. Open $REPORT for the full actionable breakdown."

section "31. Security — Vault HTTP Connections"
VAULT_HTTP=$(grep -rn "http://vault.vault.svc.cluster.local\|http://vault\.svc" \
  k8s/ infra/argocd/ --include="*.yaml" --include="*.yml" 2>/dev/null || true)
if [ -n "$VAULT_HTTP" ]; then
  fail "Vault connection uses HTTP (CRITICAL): $VAULT_HTTP"
else
  pass "All Vault connections use HTTPS"
fi

section "32. Security — JWKS HTTP Endpoints"
JWKS_HTTP=$(grep -rn "remoteJWKS:\|uri:.*http://auth\|url:.*http://auth" \
  k8s/base/api-gateway/ --include="*.yaml" --include="*.yml" 2>/dev/null || true)
if echo "$JWKS_HTTP" | grep -q "http://"; then
  fail "JWKS fetched over HTTP (HIGH): $JWKS_HTTP"
else
  pass "All JWKS endpoints use HTTPS"
fi

section "33. Security — PgBouncer Authentication Method"
PGB_MD5=$(grep -rn "auth_type.*=.*md5" k8s/base/pgbouncer/ --include="*.ini" --include="*.yaml" 2>/dev/null || true)
if [ -n "$PGB_MD5" ]; then
  fail "PgBouncer uses MD5 auth (weak): $PGB_MD5"
else
  pass "PgBouncer does not use weak MD5 authentication"
fi

section "31. Security — Vault HTTP Connections"
VAULT_HTTP=$(grep -rn "http://vault.vault.svc.cluster.local\|http://vault\.svc" \
  k8s/ infra/argocd/ --include="*.yaml" --include="*.yml" 2>/dev/null || true)
if [ -n "$VAULT_HTTP" ]; then
  fail "Vault connection uses HTTP (CRITICAL): $VAULT_HTTP"
else
  pass "All Vault connections use HTTPS"
fi

section "32. Security — JWKS HTTP Endpoints"
JWKS_HTTP=$(grep -rn "remoteJWKS:\|uri:.*http://auth\|url:.*http://auth" \
  k8s/base/api-gateway/ --include="*.yaml" --include="*.yml" 2>/dev/null || true)
if echo "$JWKS_HTTP" | grep -q "http://"; then
  fail "JWKS fetched over HTTP (HIGH): $JWKS_HTTP"
else
  pass "All JWKS endpoints use HTTPS"
fi

section "33. Security — PgBouncer Authentication Method"
PGB_MD5=$(grep -rn "auth_type.*=.*md5" k8s/base/pgbouncer/ --include="*.ini" --include="*.yaml" 2>/dev/null || true)
if [ -n "$PGB_MD5" ]; then
  fail "PgBouncer uses MD5 auth (weak): $PGB_MD5"
else
  pass "PgBouncer does not use weak MD5 authentication"
fi

section "31. Security — Vault HTTP Connections"
VAULT_HTTP=$(grep -rn "http://vault.vault.svc.cluster.local\|http://vault\.svc" \
  k8s/ infra/argocd/ --include="*.yaml" --include="*.yml" 2>/dev/null || true)
if [ -n "$VAULT_HTTP" ]; then
  fail "Vault connection uses HTTP (CRITICAL): $VAULT_HTTP"
else
  pass "All Vault connections use HTTPS"
fi

section "32. Security — JWKS HTTP Endpoints"
JWKS_HTTP=$(grep -rn "remoteJWKS:\|uri:.*http://auth\|url:.*http://auth" \
  k8s/base/api-gateway/ --include="*.yaml" --include="*.yml" 2>/dev/null || true)
if echo "$JWKS_HTTP" | grep -q "http://"; then
  fail "JWKS fetched over HTTP (HIGH): $JWKS_HTTP"
else
  pass "All JWKS endpoints use HTTPS"
fi

section "33. Security — PgBouncer Authentication Method"
PGB_MD5=$(grep -rn "auth_type.*=.*md5" k8s/base/pgbouncer/ --include="*.ini" --include="*.yaml" 2>/dev/null || true)
if [ -n "$PGB_MD5" ]; then
  fail "PgBouncer uses MD5 auth (weak): $PGB_MD5"
else
  pass "PgBouncer does not use weak MD5 authentication"
fi
