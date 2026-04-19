# ╔══════════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/terraform.tfvars ║
# ║  Fix F-TF18: added all variables defined in variables.tf            ║
# ╚══════════════════════════════════════════════════════════════════════╝

aws_region         = "eu-west-1"
cluster_name       = "platform-eu"
availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
