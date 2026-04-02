# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/variables.tf  ║
# ║  EU region — data residency + cross-region DR                    ║
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
