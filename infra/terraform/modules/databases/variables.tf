# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/databases/variables.tf       ║
# ║  Status: ✏️ MODIFIED                                             ║
# ║  Fix F-TF01: removed leaked resource block                       ║
# ║  Fix F-TF05: postgres_instance default → db.t4g.medium           ║
# ║  Fix F-TF06: multi_az default → true (production-safe)           ║
# ║  Fix F-TF03-egress: added vpc_cidr for restricted egress rule    ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used as prefix for RDS identifier and subnet group"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID from networking module"
}

# F-TF03-egress: used to restrict the RDS security group egress rule to within
# the VPC only. Without this, egress was open to 0.0.0.0/0 — unnecessary for RDS.
variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block — restricts RDS security group egress to within the VPC only."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0"], var.vpc_cidr)
    error_message = "vpc_cidr must NOT be 0.0.0.0/0 or ::/0."
  }
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
# Production must explicitly set db.r8g.large in its module call.
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
