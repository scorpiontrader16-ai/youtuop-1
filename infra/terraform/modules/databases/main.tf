# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/databases/main.tf            ║
# ║  Fix F-TF03: precondition blocks on postgres security group      ║
# ║  Fix F-TF03-egress: egress restricted to vpc_cidr                ║
# ║  Fix F-TF01-B: all hardcoded values replaced with var.*          ║
# ║  Fix CRITICAL-02: added monitoring IAM role — monitoring_interval ║
# ║    > 0 requires monitoring_role_arn or AWS rejects the instance  ║
# ╚══════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.9.0"
}

# ── RDS Enhanced Monitoring IAM Role ─────────────────────────────────────
# CRITICAL-02: aws_db_instance with monitoring_interval > 0 requires
# monitoring_role_arn. Without it, terraform apply fails with:
# "InvalidParameterCombination: Enhanced monitoring cannot be enabled
#  without a monitoring role."
# count gate: role only created when monitoring is enabled.
resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0
  name  = "${var.cluster_name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = var.monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── DB Subnet Group ───────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-db"
  subnet_ids = var.subnet_ids
  tags       = { Environment = var.environment }
}

# ── Security Group ────────────────────────────────────────────────────────
resource "aws_security_group" "postgres" {
  name        = "${var.cluster_name}-postgres"
  description = "PostgreSQL access from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from EKS node CIDR"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.eks_node_cidr]
  }

  egress {
    description = "Allow outbound within VPC only (Multi-AZ replication traffic)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Environment = var.environment }

  lifecycle {
    precondition {
      condition     = can(cidrhost(var.eks_node_cidr, 0))
      error_message = "eks_node_cidr must be a valid CIDR block (e.g. 10.0.2.0/24)."
    }
    precondition {
      condition     = !contains(["0.0.0.0/0", "::/0"], var.eks_node_cidr)
      error_message = "eks_node_cidr must NOT be 0.0.0.0/0 or ::/0. Restrict to specific EKS node subnet CIDR."
    }
  }
}

# ── RDS Instance ──────────────────────────────────────────────────────────
resource "aws_db_instance" "postgres" {
  identifier     = "${var.cluster_name}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.postgres_instance

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "platform"
  username                    = "platform_admin"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.postgres.id]

  multi_az            = var.multi_az
  publicly_accessible = false

  deletion_protection     = var.environment == "production"
  backup_retention_period = var.environment == "production" ? 30 : 7
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  skip_final_snapshot     = var.environment != "production"

  performance_insights_enabled = true
  monitoring_interval          = var.monitoring_interval
  monitoring_role_arn          = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  tags = { Environment = var.environment }
}

# ── Outputs ───────────────────────────────────────────────────────────────
output "postgres_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "postgres_secret_arn" {
  value = try(aws_db_instance.postgres.master_user_secret[0].secret_arn, "")
}

output "postgres_arn" {
  value = aws_db_instance.postgres.arn
}
