# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/variables.tf  ║
# ║  EU region — data residency + cross-region DR                    ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "aws_region" {
  description = "AWS region for EU deployment (data residency)"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name for EU environment"
  type        = string
  default     = "platform-eu"
}
