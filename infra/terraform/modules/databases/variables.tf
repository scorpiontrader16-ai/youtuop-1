# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/databases/variables.tf       ║
# ║  Fix F-TF01: removed leaked resource block                       ║
# ║  Fix F-TF05: postgres_instance default → db.t4g.medium           ║
# ║  Fix F-TF06: multi_az default → true (production-safe)           ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used as prefix for RDS identifier and subnet group"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID from networking module"
}

variable "eks_node_cidr" {
  type        = string
  description = "CIDR of the EKS node subnet — only this subnet can reach PostgreSQL on port 5432."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the RDS subnet group"
}

variable "environment" {
  type        = string
  description = "Deployment environment (staging | production)"
}

# F-TF05: default changed from db.r8g.large → db.t4g.medium
# db.r8g.large costs ~$0.48/hr — dangerous default for dev/staging.
# Production and eu-west-1 must explicitly set db.r8g.large in their module calls.
variable "postgres_instance" {
  type        = string
  default     = "db.t4g.medium"
  description = "RDS instance class. Default: db.t4g.medium (dev/staging). Production must explicitly set db.r8g.large or higher."

  validation {
    condition     = can(regex("^db\\.(t[0-9]|r[0-9]|m[0-9])", var.postgres_instance))
    error_message = "postgres_instance must be a valid RDS instance class (e.g. db.t4g.medium, db.r8g.large)."
  }
}

# F-TF06: default changed from false → true
# Multi-AZ off by default is a production footgun — any forgotten override loses HA.
# Staging explicitly sets multi_az = false in its module call, so no impact there.
variable "multi_az" {
  type        = bool
  default     = true
  description = "Enable Multi-AZ for RDS. Default: true (production-safe). Non-production must explicitly set to false."
}
