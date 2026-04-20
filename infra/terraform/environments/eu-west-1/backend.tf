# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/backend.tf    ║
# ║  Fix CRITICAL-01: was empty backend "s3" {} — local state only   ║
# ║  Same state bucket as production (same AWS account).             ║
# ║  Key scoped to eu-west-1 to avoid state collision.               ║
# ║  region = us-east-1 — where the state bucket lives.             ║
# ╚══════════════════════════════════════════════════════════════════╝

terraform {
  backend "s3" {
    bucket         = "amnix-terraform-state"
    key            = "environments/eu-west-1/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "amnix-terraform-state-locks"
  }
}
