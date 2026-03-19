variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "environment" {
  type = string
}

variable "postgres_instance" {
  type    = string
  default = "db.r8g.large"
}

variable "multi_az" {
  type    = bool
  default = false
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-db"
  subnet_ids = var.subnet_ids
  tags       = { Environment = var.environment }
}

resource "aws_security_group" "postgres" {
  name        = "${var.cluster_name}-postgres"
  description = "PostgreSQL access from VPC only"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Environment = var.environment }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.cluster_name}-postgres"
  engine         = "postgres"
  engine_version = "16.2"
  instance_class = var.postgres_instance

  allocated_storage     = 100
  max_allocated_storage = 1000
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
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  skip_final_snapshot     = var.environment != "production"

  performance_insights_enabled = true
  monitoring_interval          = 60

  tags = { Environment = var.environment }
}

output "postgres_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "postgres_secret_arn" {
  value = try(aws_db_instance.postgres.master_user_secret[0].secret_arn, "")
}

output "postgres_arn" {
  value = aws_db_instance.postgres.arn
}
