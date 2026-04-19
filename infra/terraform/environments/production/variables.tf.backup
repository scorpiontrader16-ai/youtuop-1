# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/variables.tf ║
# ║  Fix F-TF01: all hardcoded values from main.tf declared here     ║
# ║  Fix F-TF01-B: added github_org + github_repo for cluster module ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "aws_region" {
  description = "Primary AWS region for production"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "List of availability zones for the primary region"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "cluster_name" {
  description = "EKS cluster name for production"
  type        = string
  default     = "platform-prod"
}

variable "enable_mena_region" {
  description = "Enable MENA region for data sovereignty (Bahrain / UAE)"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "VPC CIDR block for production"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks for production (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks for production (one per AZ)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to access EKS API server."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "eks_node_cidr" {
  description = "CIDR permitted to reach PostgreSQL on port 5432."
  type        = string
  default     = "10.0.0.0/16"
}

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

variable "results_sync_bucket" {
  description = "S3 bucket name for cross-region results sync. Globally unique — must be set explicitly."
  type        = string
}

variable "github_org" {
  description = "GitHub organization name for OIDC trust policy in cluster module."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name for OIDC trust policy in cluster module."
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
  description = "RDS instance class for production. Must be set explicitly — no default to force conscious choice."
  type        = string

  validation {
    condition     = can(regex("^db\\.(t[0-9]|r[0-9]|m[0-9])", var.postgres_instance))
    error_message = "postgres_instance must be a valid RDS instance class (e.g. db.r8g.large, db.t4g.medium)."
  }
}
