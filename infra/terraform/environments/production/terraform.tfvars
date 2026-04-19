# ╔════════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/terraform.tfvars ║
# ║  Status: ✏️ MODIFIED                                               ║
# ║  Fix F-TF18: every variable declared in variables.tf is listed     ║
# ╚════════════════════════════════════════════════════════════════════╝

aws_region         = "us-east-1"
cluster_name       = "platform-prod"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# ── Data Sovereignty ──────────────────────────────────────────────────────
# Disabled until regional compliance review is complete
enable_mena_region = false

# ── Networking ────────────────────────────────────────────────────────────
vpc_cidr        = "10.0.0.0/16"
private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# ── EKS API Access ───────────────────────────────────────────────────────
# H-03: Replace with VPN/bastion CIDR when bastion host is provisioned
eks_public_access_cidrs = ["10.0.0.0/16"]

# ── Database Ingress ──────────────────────────────────────────────────────
# H-04: Tighten to EKS node subnet CIDR once node groups are stable
eks_node_cidr = "10.0.0.0/16"

# ── Redpanda ─────────────────────────────────────────────────────────────
redpanda_broker_count  = 3
redpanda_instance_type = "im4gn.xlarge"

# ── Cross-Region Results Sync ─────────────────────────────────────────────
# S3 bucket names are globally unique — no default in variables.tf
results_sync_bucket = "platform-results-sync-us-east-1"

# ── Postgres Cross-Region Replica ─────────────────────────────────────────
postgres_replica_retention_days = 7
