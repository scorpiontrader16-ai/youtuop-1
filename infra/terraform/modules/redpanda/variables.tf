# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/redpanda/variables.tf        ║
# ║  Fix F-TF01: removed leaked resource blocks                      ║
# ║  Fix F-TF01-B: added vpc_cidr, mirrormaker vars, volume vars     ║
# ║  Fix SG-BUG: vpc_cidr replaces hardcoded 10.0.0.0/8             ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "Cluster name — used as prefix for all Redpanda resources"
}

variable "broker_count" {
  type        = number
  default     = 3
  description = "Number of Redpanda broker EC2 instances. Minimum 3 for production HA."

  validation {
    condition     = var.broker_count >= 1
    error_message = "broker_count must be at least 1."
  }
}

variable "instance_type" {
  type        = string
  default     = "im4gn.xlarge"
  description = "EC2 instance type for Redpanda brokers (NVMe-optimized recommended)"
}

variable "environment" {
  type        = string
  description = "Deployment environment (staging | production)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID from networking module"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block — used to restrict Redpanda security group ingress to VPC traffic only. Replaces the insecure 10.0.0.0/8 supernet."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block (e.g. 10.0.0.0/16)."
  }

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0", "10.0.0.0/8"], var.vpc_cidr)
    error_message = "vpc_cidr must be a specific VPC CIDR, not a supernet or open CIDR."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs from networking module"
}

# ── MirrorMaker2 ──────────────────────────────────────────────────────────
# F-TF01-B: extracted hardcoded c7g.large instance type
variable "mirrormaker_instance_type" {
  type        = string
  default     = "c7g.large"
  description = "EC2 instance type for MirrorMaker2 cross-region sync instance. Graviton3-optimized."
}

# ── Storage ───────────────────────────────────────────────────────────────
# F-TF01-B: extracted hardcoded volume sizes
variable "broker_volume_size" {
  type        = number
  default     = 100
  description = "Root EBS volume size in GB for each Redpanda broker instance."

  validation {
    condition     = var.broker_volume_size >= 50
    error_message = "broker_volume_size must be at least 50 GB."
  }
}

variable "mirrormaker_volume_size" {
  type        = number
  default     = 50
  description = "Root EBS volume size in GB for the MirrorMaker2 instance."

  validation {
    condition     = var.mirrormaker_volume_size >= 20
    error_message = "mirrormaker_volume_size must be at least 20 GB."
  }
}

# ── Tiered Storage Lifecycle ──────────────────────────────────────────────
# F-TF01: extracted hardcoded lifecycle transition days
variable "tiered_storage_standard_ia_days" {
  type        = number
  default     = 30
  description = "Days before transitioning Redpanda tiered storage objects to STANDARD_IA."

  validation {
    condition     = var.tiered_storage_standard_ia_days >= 30
    error_message = "tiered_storage_standard_ia_days must be at least 30 (AWS S3 minimum for STANDARD_IA)."
  }
}

variable "tiered_storage_glacier_days" {
  type        = number
  default     = 90
  description = "Days before transitioning Redpanda tiered storage objects to GLACIER_IR. Must be greater than tiered_storage_standard_ia_days."

  validation {
    condition     = var.tiered_storage_glacier_days > var.tiered_storage_standard_ia_days
    error_message = "tiered_storage_glacier_days must be greater than tiered_storage_standard_ia_days."
  }
}

# ── MirrorMaker2 Subnet ───────────────────────────────────────────────────
# MEDIUM-03 FIX: extracted hardcoded [0] index to variable.
# Change to 1 or 2 if AZ-0 is degraded — no code change required.
variable "mirrormaker_subnet_index" {
  type        = number
  default     = 0
  description = "Index of private_subnet_ids to deploy MirrorMaker2 into. Default: 0 (AZ-0). Change if AZ-0 is degraded."

  validation {
    condition     = var.mirrormaker_subnet_index >= 0
    error_message = "mirrormaker_subnet_index must be >= 0."
  }
}
