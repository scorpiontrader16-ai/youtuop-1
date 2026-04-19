# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/cluster/variables.tf         ║
# ║  Fix F-TF01: removed leaked resource blocks                      ║
# ║  Fix F-TF02: added 4 validation rules to eks_public_access_cidrs ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "cluster_version" {
  type        = string
  default     = "1.29"
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

  # F-TF02: block open internet access
  validation {
    condition     = !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "eks_public_access_cidrs must NOT contain 0.0.0.0/0. Restrict to VPN or bastion CIDRs only."
  }

  # F-TF02: block IPv6 open access
  validation {
    condition     = !contains(var.eks_public_access_cidrs, "::/0")
    error_message = "eks_public_access_cidrs must NOT contain ::/0. Restrict to VPN or bastion CIDRs only."
  }

  # F-TF02: all entries must be valid CIDR notation
  validation {
    condition     = alltrue([for cidr in var.eks_public_access_cidrs : can(cidrhost(cidr, 0))])
    error_message = "All entries in eks_public_access_cidrs must be valid CIDR blocks (e.g. 10.0.1.0/24)."
  }

  # F-TF02: list must not be empty
  validation {
    condition     = length(var.eks_public_access_cidrs) > 0
    error_message = "eks_public_access_cidrs must contain at least one CIDR. Do not leave EKS public access unrestricted."
  }
}
