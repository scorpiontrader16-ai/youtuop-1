# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/staging/terraform.tfvars║
# ║  Fix F-TF18: every variable declared in variables.tf is listed   ║
# ║  Fix F-TF01-B: added github_org + github_repo                    ║
# ║  Fix F-TF01-C: multi_az explicit                                 ║
# ║  Fix CRITICAL-03: create_account_global_resources = false        ║
# ║    staging shares AWS account with production (same state bucket) ║
# ║    production owns account-global resources to avoid conflict on  ║
# ║    aws_s3_account_public_access_block + aws_guardduty_detector   ║
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
multi_az = false

# ── Account-Global Resources ──────────────────────────────────────────────
# CRITICAL-03 FIX: false — staging shares the same AWS account as production.
# production state owns aws_s3_account_public_access_block + aws_guardduty_detector.
# Two states owning the same account-level resource = apply conflict.
create_account_global_resources = false

# ── CloudTrail ────────────────────────────────────────────────────────────
# false — production already owns the multi-region trail covering us-east-1.
# Two multi-region trails in the same account = duplicate logs + double cost.
cloudtrail_multi_region = false
