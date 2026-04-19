# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/networking/variables.tf      ║
# ║  Fix F-TF01: removed leaked resource block (aws_vpc)             ║
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
