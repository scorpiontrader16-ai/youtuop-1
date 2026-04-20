# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/variables.tf ║
# ║  Fix F-TF01: all hardcoded values from main.tf declared here     ║
# ║  Fix F-TF01-B: added github_org + github_repo for cluster module ║
# ║  Fix F-TF01-C: added multi_az + postgres_instance               ║
# ║  Fix MEDIUM-04: removed enable_mena_region (dead variable)       ║
# ║  Fix MEDIUM-05: added results_sync lifecycle variables            ║
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
variable "multi_az" {
  description = "Enable Multi-AZ for RDS. Default: true (production-safe)."
  type        = bool
  default     = true
}

variable "postgres_instance" {
  description = "RDS instance class for production. No default — must be conscious choice."
  type        = string

  validation {
    condition     = can(regex("^db\\.(t[0-9]|r[0-9]|m[0-9])", var.postgres_instance))
    error_message = "postgres_instance must be a valid RDS instance class (e.g. db.r8g.large)."
  }
}

# ── Account-Global Resources ──────────────────────────────────────────────
variable "create_account_global_resources" {
  description = "Create account-global resources (GitHub OIDC + S3 account block + GuardDuty). True for primary state only."
  type        = bool
  default     = true
}

variable "cloudtrail_multi_region" {
  description = "Enable multi-region CloudTrail. True for primary state, false for secondary."
  type        = bool
  default     = true
}

# ── Results Sync Lifecycle ────────────────────────────────────────────────
# MEDIUM-05: explicit retention policy — financial platform requires defined data lifecycle.
variable "results_sync_standard_ia_days" {
  description = "Days before transitioning results_sync objects to STANDARD_IA."
  type        = number
  default     = 30

  validation {
    condition     = var.results_sync_standard_ia_days >= 30
    error_message = "results_sync_standard_ia_days must be >= 30 (AWS S3 minimum for STANDARD_IA)."
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
  description = "Days before expiring results_sync objects. Financial data retention: 365 days minimum."
  type        = number
  default     = 365

  validation {
    condition     = var.results_sync_expiration_days >= 365
    error_message = "results_sync_expiration_days must be >= 365 for financial data compliance."
  }
}

# ── Route53 DR Failover ───────────────────────────────────────────────────
# These variables are populated after ingress controller is deployed in both clusters.
# Run: kubectl get svc -n ingress-nginx to get LB DNS names.

variable "domain_name" {
  description = "Root domain name for Route53 hosted zone (e.g. amnixfinance.com)."
  type        = string
  default     = "amnixfinance.com"
}

variable "primary_lb_dns" {
  description = "DNS name of the primary ALB (us-east-1). Set after ingress controller deploy."
  type        = string
}

variable "primary_lb_zone_id" {
  description = "Hosted zone ID of the primary ALB (us-east-1). Get from: aws elbv2 describe-load-balancers."
  type        = string
}

variable "dr_lb_dns" {
  description = "DNS name of the DR ALB (eu-west-1). Set after ingress controller deploy in DR cluster."
  type        = string
}

variable "dr_lb_zone_id" {
  description = "Hosted zone ID of the DR ALB (eu-west-1)."
  type        = string
}

variable "sns_alarm_arn" {
  description = "SNS topic ARN for DR health check alerts (platform-dr-alerts). Leave empty to skip alarm."
  type        = string
  default     = ""
}
