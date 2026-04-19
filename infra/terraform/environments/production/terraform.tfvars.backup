# ╔════════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/terraform.tfvars ║
# ║  Fix F-TF18: every variable declared in variables.tf is listed    ║
# ║  Fix F-TF01-B: added github_org + github_repo                     ║
# ╚════════════════════════════════════════════════════════════════════╝

aws_region         = "us-east-1"
cluster_name       = "platform-prod"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

enable_mena_region = false

vpc_cidr        = "10.0.0.0/16"
private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

eks_public_access_cidrs = ["10.0.0.0/16"]
eks_node_cidr           = "10.0.0.0/16"

redpanda_broker_count  = 3
redpanda_instance_type = "im4gn.xlarge"

results_sync_bucket = "platform-results-sync-us-east-1"

github_org  = "scorpiontrader16-ai"
github_repo = "AmniX-Finance"

# ── RDS ───────────────────────────────────────────────────────────────────
# Fix F-TF01-C: previously hardcoded in main.tf — now explicit in tfvars
multi_az          = true
postgres_instance = "db.r8g.large"
