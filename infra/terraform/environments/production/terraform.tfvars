# ╔════════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/terraform.tfvars ║
# ║  Fix F-TF18: added all variables defined in variables.tf           ║
# ╚════════════════════════════════════════════════════════════════════╝

aws_region         = "us-east-1"
cluster_name       = "platform-prod"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# Data sovereignty — MENA region disabled until explicit decision is made
# Change to true only after regional compliance review is complete
enable_mena_region = false
