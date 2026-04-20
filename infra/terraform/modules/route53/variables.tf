# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/route53/variables.tf         ║
# ║  DR health checks + failover routing for api.amnixfinance.com    ║
# ║  Outputs: health_check_id, hosted_zone_id, dr_lb_dns             ║
# ║  Used by RUNBOOK.md Phase 1/4 failover procedure                 ║
# ╚══════════════════════════════════════════════════════════════════╝

variable "domain_name" {
  type        = string
  description = "Root domain name (e.g. amnixfinance.com). Must match existing Route53 hosted zone."
}

variable "api_subdomain" {
  type        = string
  default     = "api"
  description = "API subdomain prefix. Final record: <api_subdomain>.<domain_name>"
}

variable "primary_lb_dns" {
  type        = string
  description = "DNS name of the primary region ALB/NLB (us-east-1). Obtain from: kubectl get svc -n ingress-nginx after ingress controller deploy."
}

variable "primary_lb_zone_id" {
  type        = string
  description = "Hosted zone ID of the primary region ALB/NLB. Obtain from AWS console or: aws elbv2 describe-load-balancers."
}

variable "dr_lb_dns" {
  type        = string
  description = "DNS name of the DR region ALB/NLB (eu-west-1). Obtain after ingress controller deploy in DR cluster."
}

variable "dr_lb_zone_id" {
  type        = string
  description = "Hosted zone ID of the DR region ALB/NLB (eu-west-1)."
}

variable "health_check_path" {
  type        = string
  default     = "/healthz"
  description = "HTTP path for Route53 health check. Must return 2xx within failure_threshold * request_interval seconds."
}

variable "health_check_port" {
  type        = number
  default     = 443
  description = "Port for Route53 health check. 443 = HTTPS (production standard)."
}

variable "failure_threshold" {
  type        = number
  default     = 3
  description = "Number of consecutive health check failures before marking unhealthy. RUNBOOK trigger: 3 failures = DR failover."

  validation {
    condition     = var.failure_threshold >= 1 && var.failure_threshold <= 10
    error_message = "failure_threshold must be between 1 and 10."
  }
}

variable "request_interval" {
  type        = number
  default     = 30
  description = "Seconds between health checks. 30 = standard. 10 = fast (higher cost)."

  validation {
    condition     = contains([10, 30], var.request_interval)
    error_message = "request_interval must be 10 (fast) or 30 (standard)."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment (staging | production)"
}

variable "sns_alarm_arn" {
  type        = string
  default     = ""
  description = "SNS topic ARN for CloudWatch alarm notifications on health check failure. Leave empty to skip alarm. RUNBOOK references: platform-dr-alerts topic."
}
