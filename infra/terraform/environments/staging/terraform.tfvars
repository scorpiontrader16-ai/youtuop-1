# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/staging/terraform.tfvars║
# ║  Fix F-TF18: every variable declared in variables.tf is listed   ║
# ║  Fix F-TF01-B: added github_org + github_repo                    ║
# ╚══════════════════════════════════════════════════════════════════╝

aws_region         = "us-east-1"
cluster_name       = "platform-staging"
availability_zones = ["us-east-1a", "us-east-1b"]

vpc_cidr        = "10.1.0.0/16"
private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
public_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]

eks_public_access_cidrs = ["10.1.0.0/16"]
eks_node_cidr           = "10.1.0.0/16"

redpanda_broker_count  = 1
redpanda_instance_type = "im4gn.xlarge"

github_org  = "scorpiontrader16-ai"
github_repo = "AmniX-Finance"

# ── RDS ───────────────────────────────────────────────────────────────────
# Fix F-TF01-C: multi_az was hardcoded false in main.tf — now explicit
multi_az = false

# ── Account-Global Resources ──────────────────────────────────────────────
create_account_global_resources = true

# ── CloudTrail ───────────────────────────────────────────────────────────
# H-03: staging is a separate account — owns its own multi-region trail
cloudtrail_multi_region = true
