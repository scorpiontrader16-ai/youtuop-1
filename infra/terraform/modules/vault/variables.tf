# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/vault/variables.tf           ║
# ║  Fix F-TF01: removed leaked resource block (vault_kms policy)    ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used as prefix for IAM roles and S3 bucket"
}

variable "environment" {
  type        = string
  description = "Deployment environment (staging | production)"
}

variable "kms_key_id" {
  type        = string
  description = "KMS key ARN for Vault auto-unseal and S3 encryption"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS OIDC provider ARN for IRSA trust policy"
}

variable "oidc_provider_url" {
  type        = string
  description = "EKS OIDC provider URL (without https://) for condition keys"
}

variable "namespace" {
  type        = string
  default     = "platform"
  description = "Kubernetes namespace for platform workloads"
}
