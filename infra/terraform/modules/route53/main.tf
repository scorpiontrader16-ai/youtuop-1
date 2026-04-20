# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/route53/main.tf              ║
# ║  DR health checks + failover routing for api.amnixfinance.com    ║
# ║  Architecture:                                                   ║
# ║    PRIMARY (us-east-1) → failover PRIMARY record                 ║
# ║    DR      (eu-west-1) → failover SECONDARY record               ║
# ║    Route53 health check → triggers automatic failover            ║
# ║    CloudWatch alarm → SNS → on-call (RUNBOOK Phase 1)            ║
# ╚══════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Hosted Zone (data source — zone created outside Terraform or manually) ──
# The hosted zone for amnixfinance.com is the account-level DNS authority.
# We reference it by data source — never recreate it (destroys all DNS records).
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ── Health Check — Primary Region ─────────────────────────────────────────
# Monitors the primary ALB endpoint every request_interval seconds.
# After failure_threshold consecutive failures → Route53 marks PRIMARY unhealthy
# → traffic automatically shifts to SECONDARY (DR).
# This is the $HEALTH_CHECK_ID referenced in RUNBOOK.md Phase 1.
resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_lb_dns
  port              = var.health_check_port
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = var.failure_threshold
  request_interval  = var.request_interval

  tags = {
    Name        = "platform-primary-region-health"
    Environment = var.environment
    Purpose     = "DR-failover-trigger"
  }
}

# ── CloudWatch Alarm — Health Check Failure ───────────────────────────────
# Triggers SNS notification when primary health check fails.
# RUNBOOK references: CloudWatch alarm "platform-primary-region-health"
# and SNS topic "platform-dr-alerts" — this creates both bindings.
resource "aws_cloudwatch_metric_alarm" "primary_health" {
  count = var.sns_alarm_arn != "" ? 1 : 0

  alarm_name          = "platform-primary-region-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = var.request_interval
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Primary region health check failed — initiate DR runbook"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }

  alarm_actions = [var.sns_alarm_arn]
  ok_actions    = [var.sns_alarm_arn]

  tags = {
    Environment = var.environment
    Purpose     = "DR-failover-alert"
  }
}

# ── DNS Failover — PRIMARY record (us-east-1) ─────────────────────────────
# Active record when primary health check is healthy.
# Points to primary region ALB via Alias record (no TTL cost, instant failover).
resource "aws_route53_record" "api_primary" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.api_subdomain}.${var.domain_name}"
  type    = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id

  alias {
    name                   = var.primary_lb_dns
    zone_id                = var.primary_lb_zone_id
    evaluate_target_health = true
  }
}

# ── DNS Failover — SECONDARY record (eu-west-1) ───────────────────────────
# Passive record — receives traffic only when primary health check fails.
# No health check on SECONDARY — Route53 always keeps it as fallback.
# RUNBOOK Phase 4 DNS failover updates this record's active status automatically
# via the health check — manual DNS change only needed for failback.
resource "aws_route53_record" "api_dr" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.api_subdomain}.${var.domain_name}"
  type    = "A"

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "dr"

  alias {
    name                   = var.dr_lb_dns
    zone_id                = var.dr_lb_zone_id
    evaluate_target_health = true
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────
# These values populate RUNBOOK.md environment variables:
#   $HEALTH_CHECK_ID → aws_route53_health_check.primary.id
#   $HOSTED_ZONE_ID  → data.aws_route53_zone.main.zone_id
#   $DR_LB_DNS       → var.dr_lb_dns (passed from environment)
#   $DR_LB_ZONE_ID   → var.dr_lb_zone_id (passed from environment)

output "health_check_id" {
  value       = aws_route53_health_check.primary.id
  description = "Route53 health check ID — use as $HEALTH_CHECK_ID in RUNBOOK.md Phase 1."
}

output "hosted_zone_id" {
  value       = data.aws_route53_zone.main.zone_id
  description = "Route53 hosted zone ID — use as $HOSTED_ZONE_ID in RUNBOOK.md Phase 4."
}

output "api_fqdn" {
  value       = "${var.api_subdomain}.${var.domain_name}"
  description = "Fully qualified API domain name (e.g. api.amnixfinance.com)."
}

output "primary_record_name" {
  value       = aws_route53_record.api_primary.fqdn
  description = "Primary failover DNS record FQDN."
}

output "dr_record_name" {
  value       = aws_route53_record.api_dr.fqdn
  description = "DR failover DNS record FQDN."
}
