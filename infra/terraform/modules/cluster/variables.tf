# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/cluster/variables.tf         ║
# ║  Fix F-TF01: removed leaked resource blocks                      ║
# ║  Fix F-TF02: added 4 validation rules to eks_public_access_cidrs ║
# ║  Fix F-TF01-B: extracted all hardcoded values to variables        ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "cluster_version" {
  type        = string
  default     = "1.31"
  description = "Kubernetes version for the EKS cluster"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID from networking module"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EKS control plane"
}

variable "environment" {
  type        = string
  description = "Deployment environment (staging | production)"
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access EKS API server. Must be restricted to VPN/bastion IPs only. No default — must be set explicitly per environment."

  validation {
    condition     = !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "eks_public_access_cidrs must NOT contain 0.0.0.0/0. Restrict to VPN or bastion CIDRs only."
  }

  validation {
    condition     = !contains(var.eks_public_access_cidrs, "::/0")
    error_message = "eks_public_access_cidrs must NOT contain ::/0. Restrict to VPN or bastion CIDRs only."
  }

  validation {
    condition     = alltrue([for cidr in var.eks_public_access_cidrs : can(cidrhost(cidr, 0))])
    error_message = "All entries in eks_public_access_cidrs must be valid CIDR blocks (e.g. 10.0.1.0/24)."
  }

  validation {
    condition     = length(var.eks_public_access_cidrs) > 0
    error_message = "eks_public_access_cidrs must contain at least one CIDR. Do not leave EKS public access unrestricted."
  }
}

# ── Node Group ────────────────────────────────────────────────────────────
# F-TF01-B: extracted from hardcoded values in aws_eks_node_group.arm64

variable "node_instance_types" {
  type        = list(string)
  default     = ["r8g.xlarge", "r8g.2xlarge"]
  description = "EC2 instance types for the ARM64 node group. Graviton3-optimized."
}

variable "node_desired_size" {
  type        = number
  default     = 3
  description = "Desired number of nodes in the EKS node group."

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
    error_message = "node_desired_size must be between node_min_size and node_max_size."
  }
}

variable "node_min_size" {
  type        = number
  default     = 2
  description = "Minimum number of nodes in the EKS node group."

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be at least 1."
  }
}

variable "node_max_size" {
  type        = number
  default     = 20
  description = "Maximum number of nodes in the EKS node group for autoscaling."

  validation {
    condition     = var.node_max_size >= var.node_min_size
    error_message = "node_max_size must be greater than or equal to node_min_size."
  }
}

# ── GitHub Actions OIDC ───────────────────────────────────────────────────
# F-TF01-B: extracted hardcoded repo path from IAM assume role policy.
# Format: org/repo — do NOT include refs/heads/ prefix.

variable "github_org" {
  type        = string
  description = "GitHub organization name for OIDC trust policy (e.g. my-org)."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name for OIDC trust policy (e.g. AmniX-Finance)."
}

variable "github_branch" {
  type        = string
  default     = "main"
  description = "GitHub branch for OIDC trust policy. Only this branch can assume the GitHub Actions role."
}

# ── Helm Chart Versions ───────────────────────────────────────────────────
# F-TF01-B: extracted from hardcoded helm_release version fields.
# Pin versions explicitly — never use latest to avoid unexpected upgrades in production.

variable "cert_manager_version" {
  type        = string
  default     = "v1.14.4"
  description = "Helm chart version for cert-manager. Pin explicitly. See: https://github.com/cert-manager/cert-manager/releases"
}

variable "external_secrets_version" {
  type        = string
  default     = "0.9.13"
  description = "Helm chart version for external-secrets-operator. Pin explicitly. See: https://github.com/external-secrets/external-secrets/releases"
}

# ── Account-Global Resources Gate ────────────────────────────────────────
# C-01/C-02: aws_iam_openid_connect_provider.github and
# aws_s3_account_public_access_block are AWS account-global resources.
# Only ONE Terraform state per account may own them.
# Set true in the primary state (production us-east-1, or standalone staging).
# Set false in all secondary states (eu-west-1) to prevent EntityAlreadyExists.
variable "create_account_global_resources" {
  type        = bool
  description = "Create account-global resources: GitHub OIDC provider + S3 account public access block. Set true in primary state only. Set false in secondary states (eu-west-1) to prevent conflicts."
}

# ── CloudTrail ────────────────────────────────────────────────────────────
# H-03: only one state per AWS account should own the multi-region trail.
# Primary state (production us-east-1) sets true.
# Secondary states (eu-west-1) set false — primary trail already covers all regions.
# Duplicate multi-region trails = duplicate logs + unnecessary cost.
variable "cloudtrail_multi_region" {
  type        = bool
  default     = true
  description = "Enable multi-region CloudTrail. Set true in primary state only. Set false in secondary states (eu-west-1) to prevent duplicate trails."
}
