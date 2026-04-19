# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/staging/variables.tf    ║
# ║  Status: ✏️ MODIFIED                                             ║
# ║  Fix F-TF01: moved all hardcoded values from main.tf into here   ║
# ║  Fix F-TF18: all variables for this environment declared here    ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "aws_region" {
  description = "AWS region for staging environment"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "List of availability zones for the region"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "cluster_name" {
  description = "EKS cluster name for staging"
  type        = string
  default     = "platform-staging"
}

# ── Networking ────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "VPC CIDR block for staging"
  type        = string
  default     = "10.1.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks for staging (one per AZ)"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks for staging (one per AZ)"
  type        = list(string)
  default     = ["10.1.101.0/24", "10.1.102.0/24"]
}

# ── EKS API Access ───────────────────────────────────────────────────────
# H-03: Currently set to full VPC CIDR — intentional, pending bastion host.
# Narrow to VPN/bastion CIDR when bastion is provisioned.

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to access EKS API server. Narrow to VPN/bastion when bastion is ready."
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

# ── Database Ingress ──────────────────────────────────────────────────────
# H-04: Currently set to full VPC CIDR — intentional, pending stable node groups.
# Narrow to EKS node subnet CIDR once node groups are stable.

variable "eks_node_cidr" {
  description = "CIDR permitted to reach PostgreSQL on port 5432. Narrow to EKS node subnet once stable."
  type        = string
  default     = "10.1.0.0/16"
}

# ── Redpanda ─────────────────────────────────────────────────────────────
# broker_count = 1 is correct for staging — no HA required.

variable "redpanda_broker_count" {
  description = "Number of Redpanda broker EC2 instances. 1 for staging (no HA), 3 for production."
  type        = number
  default     = 1
}

variable "redpanda_instance_type" {
  description = "EC2 instance type for Redpanda brokers. NVMe-optimized (im4gn) recommended."
  type        = string
  default     = "im4gn.xlarge"
}
