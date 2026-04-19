# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/redpanda/variables.tf        ║
# ║  Fix F-TF01: removed leaked resource blocks                      ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "Cluster name — used as prefix for all Redpanda resources"
}

variable "broker_count" {
  type        = number
  default     = 3
  description = "Number of Redpanda broker EC2 instances"
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

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs from networking module"
}
