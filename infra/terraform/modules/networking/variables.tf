# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/networking/variables.tf      ║
# ║  Fix F-TF01: removed leaked resource block (aws_vpc)             ║
# ║  Fix HIGH-03: added enable_flow_logs + flow_logs_retention_days  ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "name" {
  type        = string
  description = "Name prefix for all networking resources"
}

variable "cidr" {
  type        = string
  description = "VPC CIDR block"
}

variable "azs" {
  type        = list(string)
  description = "List of availability zones to deploy subnets into"
}

variable "private_subnets" {
  type        = list(string)
  description = "CIDR blocks for private subnets (one per AZ)"
}

variable "public_subnets" {
  type        = list(string)
  description = "CIDR blocks for public subnets (one per AZ)"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used for kubernetes.io/cluster/* tags"
}

# ── VPC Flow Logs ─────────────────────────────────────────────────────────
# HIGH-03: enabled by default — financial platform compliance requirement.
# Set false only in staging where cost saving is prioritized over full compliance.
variable "enable_flow_logs" {
  type        = bool
  default     = true
  description = "Enable VPC Flow Logs to CloudWatch. Default: true. Required for PCI-DSS + SOC2."
}

variable "flow_logs_retention_days" {
  type        = number
  default     = 90
  description = "CloudWatch log retention in days for VPC flow logs. Default: 90 (3 months)."

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be a valid CloudWatch retention value."
  }
}
