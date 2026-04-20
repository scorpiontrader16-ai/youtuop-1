# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/variables.tf  ║
# ║  Fix F-TF01: moved all hardcoded values from main.tf into here   ║
# ║  Fix F-TF18: all variables for this environment declared here    ║
# ║  Fix X-01:  added source_db_instance_arn + retention_days        ║
# ║  Fix ARN-BUG: added results_sync_bucket_us — removes hardcoded  ║
# ║    ARN from replication destination in main.tf                   ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "aws_region" {
  description = "AWS region for EU deployment (data residency)"
  type        = string
  default     = "eu-west-1"
}

variable "availability_zones" {
  description = "List of availability zones for the region"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

variable "cluster_name" {
  description = "EKS cluster name for EU environment"
  type        = string
  default     = "platform-eu"
}

# ── Networking ────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR block for eu-west-1"
  type        = string
  default     = "10.2.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks for eu-west-1 (one per AZ)"
  type        = list(string)
  default     = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks for eu-west-1 (one per AZ)"
  type        = list(string)
  default     = ["10.2.101.0/24", "10.2.102.0/24", "10.2.103.0/24"]
}

# ── EKS API Access ───────────────────────────────────────────────────────
variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to access EKS API server. Narrow to VPN/bastion when bastion is ready."
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

# ── Database Ingress ──────────────────────────────────────────────────────
variable "eks_node_cidr" {
  description = "CIDR permitted to reach PostgreSQL on port 5432."
  type        = string
  default     = "10.2.0.0/16"
}

# ── Redpanda ─────────────────────────────────────────────────────────────
variable "redpanda_broker_count" {
  description = "Number of Redpanda broker EC2 instances."
  type        = number
  default     = 3
}

variable "redpanda_instance_type" {
  description = "EC2 instance type for Redpanda brokers."
  type        = string
  default     = "im4gn.xlarge"
}

# ── Cross-Region Results Sync — EU Side ──────────────────────────────────
variable "results_sync_bucket_eu" {
  description = "S3 bucket name for EU side of cross-region results sync. Globally unique — must be explicit."
  type        = string
}

# ARN-BUG FIX: results_sync_bucket_us replaces hardcoded
# "arn:aws:s3:::platform-results-sync-us-east-1" in replication destination.
# The US bucket name must be passed explicitly — never hardcoded in module code.
variable "results_sync_bucket_us" {
  description = "S3 bucket name for US side (production state) used as replication destination ARN. Must match production terraform.tfvars results_sync_bucket value."
  type        = string
}

# ── Postgres Cross-Region Backup Replication ──────────────────────────────
variable "source_db_instance_arn" {
  description = "ARN of the source RDS instance in us-east-1 (production state output: postgres_arn)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:rds:", var.source_db_instance_arn))
    error_message = "source_db_instance_arn must be a valid RDS ARN (arn:aws:rds:...). Run: terraform output postgres_arn in production state."
  }
}

variable "postgres_replica_retention_days" {
  description = "Automated backup retention days for the eu-west-1 Postgres replica. AWS RDS limit: 7–35."
  type        = number
  default     = 7

  validation {
    condition     = var.postgres_replica_retention_days >= 7 && var.postgres_replica_retention_days <= 35
    error_message = "postgres_replica_retention_days must be between 7 and 35 (AWS RDS limit)."
  }
}

# ── GitHub Actions (passed to cluster module) ─────────────────────────────
variable "github_org" {
  description = "GitHub organization name for OIDC trust policy."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name for OIDC trust policy."
  type        = string
}

# ── RDS ───────────────────────────────────────────────────────────────────
# Fix F-TF01-C: extracted hardcoded multi_az = true from main.tf
variable "multi_az" {
  description = "Enable Multi-AZ for RDS. Default: true (production-safe). Must be explicit per environment."
  type        = bool
  default     = true
}

# Fix F-TF01-C: extracted hardcoded postgres_instance = db.r8g.large from main.tf
variable "postgres_instance" {
  description = "RDS instance class for eu-west-1. Must be set explicitly — no default to force conscious choice."
  type        = string

  validation {
    condition     = can(regex("^db\\.(t[0-9]|r[0-9]|m[0-9])", var.postgres_instance))
    error_message = "postgres_instance must be a valid RDS instance class (e.g. db.r8g.large, db.t4g.medium)."
  }
}

# ── Account-Global Resources ──────────────────────────────────────────────
# C-01/C-02: eu-west-1 is secondary — production us-east-1 owns these resources.
# Must remain false to prevent EntityAlreadyExists conflicts.
variable "create_account_global_resources" {
  description = "Create account-global resources. Must be false for eu-west-1."
  type        = bool
  default     = false
}

# ── CloudTrail ───────────────────────────────────────────────────────────
# H-03: eu-west-1 = secondary state — production trail covers all regions
variable "cloudtrail_multi_region" {
  description = "Enable multi-region CloudTrail. Must be false for eu-west-1."
  type        = bool
  default     = false
}

# ── Results Sync Lifecycle ────────────────────────────────────────────────
# MEDIUM-05: explicit retention policy for EU financial data.
variable "results_sync_standard_ia_days" {
  description = "Days before transitioning results_sync objects to STANDARD_IA."
  type        = number
  default     = 30

  validation {
    condition     = var.results_sync_standard_ia_days >= 30
    error_message = "results_sync_standard_ia_days must be >= 30."
  }
}

variable "results_sync_glacier_days" {
  description = "Days before transitioning results_sync objects to GLACIER_IR."
  type        = number
  default     = 90

  validation {
    condition     = var.results_sync_glacier_days > var.results_sync_standard_ia_days
    error_message = "results_sync_glacier_days must be > results_sync_standard_ia_days."
  }
}

variable "results_sync_expiration_days" {
  description = "Days before expiring results_sync objects. Financial data: 365 days minimum."
  type        = number
  default     = 365

  validation {
    condition     = var.results_sync_expiration_days >= 365
    error_message = "results_sync_expiration_days must be >= 365 for financial data compliance."
  }
}
