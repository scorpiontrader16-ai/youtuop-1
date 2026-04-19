# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/staging/terraform.tfvars ║
# ║  Fix F-TF18: added all variables defined in variables.tf         ║
# ╚══════════════════════════════════════════════════════════════════╝

aws_region         = "us-east-1"
cluster_name       = "platform-staging"
availability_zones = ["us-east-1a", "us-east-1b"]
