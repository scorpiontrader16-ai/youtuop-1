# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/variables.tf ║
# ║  Status: 🆕 New — M7 Data Sovereignty Stub                      ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Data Sovereignty — MENA Region ───────────────────────────────────────
# يتحكم في تفعيل البنية التحتية في منطقة MENA (البحرين / الإمارات)
# القيمة الافتراضية false — لا يُفعَّل إلا بقرار صريح
# يُستخدم في: modules/networking, modules/cluster, modules/databases
variable "enable_mena_region" {
  description = "Enable MENA region for data sovereignty (Bahrain ap-southeast-3 / UAE me-central-1)"
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "AWS region for production environment"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "List of availability zones for the region"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "cluster_name" {
  description = "EKS cluster name for production"
  type        = string
  default     = "platform-prod"
}
