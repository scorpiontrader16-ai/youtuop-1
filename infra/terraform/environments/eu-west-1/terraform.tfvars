# ╔══════════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/terraform.tfvars ║
# ║  Fix F-TF18: every variable declared in variables.tf is listed      ║
# ║  Fix ARN-BUG: results_sync_bucket_us added                          ║
# ╚══════════════════════════════════════════════════════════════════════╝

aws_region         = "eu-west-1"
cluster_name       = "platform-eu"
availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

# ── Networking ────────────────────────────────────────────────────────────
vpc_cidr        = "10.2.0.0/16"
private_subnets = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]
public_subnets  = ["10.2.101.0/24", "10.2.102.0/24", "10.2.103.0/24"]

# ── EKS API Access ───────────────────────────────────────────────────────
# H-03: Replace with VPN/bastion CIDR when bastion host is provisioned
eks_public_access_cidrs = ["10.2.0.0/16"]

# ── Database Ingress ──────────────────────────────────────────────────────
# H-04: Tighten to EKS node subnet CIDR once node groups are stable
eks_node_cidr = "10.2.0.0/16"

# ── Redpanda ─────────────────────────────────────────────────────────────
redpanda_broker_count  = 3
redpanda_instance_type = "im4gn.xlarge"

# ── Cross-Region Results Sync ─────────────────────────────────────────────
results_sync_bucket_eu = "platform-results-sync-eu-west-1"
# ARN-BUG FIX: must match production tfvars results_sync_bucket value
results_sync_bucket_us = "platform-results-sync-us-east-1"

# ── Postgres Cross-Region Backup Replication ──────────────────────────────
# REQUIRED: copy from production Terraform output before applying.
# Run: cd infra/terraform/environments/production && terraform output postgres_arn
source_db_instance_arn          = "REPLACE_WITH_PRODUCTION_POSTGRES_ARN"
postgres_replica_retention_days = 7

# ── GitHub Actions ────────────────────────────────────────────────────────
github_org  = "scorpiontrader16-ai"
github_repo = "AmniX-Finance"

# ── RDS ───────────────────────────────────────────────────────────────────
# Fix F-TF01-C: previously hardcoded in main.tf — now explicit in tfvars
multi_az          = true
postgres_instance = "db.r8g.large"

# ── Account-Global Resources ──────────────────────────────────────────────
create_account_global_resources = false

# ── CloudTrail ───────────────────────────────────────────────────────────
# H-03: false — production us-east-1 trail already covers eu-west-1 events
cloudtrail_multi_region = false

# ── Results Sync Lifecycle ────────────────────────────────────────────────
results_sync_standard_ia_days = 30
results_sync_glacier_days     = 90
results_sync_expiration_days  = 365
