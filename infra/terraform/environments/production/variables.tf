# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/variables.tf ║
# ║  Status: ✏️ MODIFIED                                             ║
# ║  Fix F-TF01: moved all hardcoded values from main.tf into here   ║
# ║  Fix F-TF18: all variables for this environment declared here    ║
# ║  Fix X-04:  results_sync_bucket added (no default — globally     ║
# ║             unique, must be explicit in tfvars)                   ║
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

# ── Data Sovereignty — MENA Region ───────────────────────────────────────
# M7-STUB: Controls future MENA infrastructure (Bahrain / UAE).
# Default false — activate only after explicit regional compliance review.
# Wired into locals.enable_mena in main.tf — all M7 resources gate on it.

variable "enable_mena_region" {
  description = "Enable MENA region for data sovereignty (Bahrain ap-southeast-3 / UAE me-central-1)"
  type        = bool
  default     = false
}

# ── Networking ────────────────────────────────────────────────────────────

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

# ── EKS API Access ───────────────────────────────────────────────────────
# H-03: Currently set to full VPC CIDR — intentional, pending bastion host.
# Narrow to VPN/bastion CIDR when bastion is provisioned.

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to access EKS API server. Narrow to VPN/bastion when bastion is ready."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

# ── Database Ingress ──────────────────────────────────────────────────────
# H-04: Currently set to full VPC CIDR — intentional, pending stable node groups.
# Narrow to EKS node subnet CIDR once node groups are stable.

variable "eks_node_cidr" {
  description = "CIDR permitted to reach PostgreSQL on port 5432. Narrow to EKS node subnet once stable."
  type        = string
  default     = "10.0.0.0/16"
}

# ── Redpanda ─────────────────────────────────────────────────────────────

variable "redpanda_broker_count" {
  description = "Number of Redpanda broker EC2 instances. 3 = minimum HA for production."
  type        = number
  default     = 3
}

variable "redpanda_instance_type" {
  description = "EC2 instance type for Redpanda brokers. NVMe-optimized (im4gn) recommended."
  type        = string
  default     = "im4gn.xlarge"
}

# ── Cross-Region Results Sync ─────────────────────────────────────────────
# X-04: No default — S3 bucket names are globally unique across all AWS accounts.
# A hardcoded default risks name collision or accidental bucket creation in wrong account.
# Must be set explicitly in terraform.tfvars.

variable "results_sync_bucket" {
  description = "S3 bucket name for cross-region results sync. Globally unique — must be set explicitly in tfvars."
  type        = string
}

# ── Postgres Cross-Region Replica ─────────────────────────────────────────

variable "postgres_replica_retention_days" {
  description = "Automated backup retention days for the eu-west-1 Postgres replica. AWS RDS limit: 7–35."
  type        = number
  default     = 7

  validation {
    condition     = var.postgres_replica_retention_days >= 7 && var.postgres_replica_retention_days <= 35
    error_message = "postgres_replica_retention_days must be between 7 and 35 (AWS RDS limit)."
  }
}
