variable "cluster_name" {
  type = string
}

variable "broker_count" {
  type    = number
  default = 3
}

variable "instance_type" {
  type    = string
  default = "im4gn.xlarge"
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "kafka_version" {
  type    = string
  default = "3.7.0"
}

# ── Data Sources ─────────────────────────────────────────────────────────
# أحدث AMI لـ ARM64 Amazon Linux 2023
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── S3 — Tiered Storage ──────────────────────────────────────────────────
resource "aws_s3_bucket" "tiered" {
  bucket = "${var.cluster_name}-redpanda-tiered"
  tags   = { Environment = var.environment }
}

resource "aws_s3_bucket_versioning" "tiered" {
  bucket = aws_s3_bucket.tiered.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tiered" {
  bucket = aws_s3_bucket.tiered.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tiered" {
  bucket = aws_s3_bucket.tiered.id
  rule {
    id     = "archive-old-segments"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }
}

# ── S3 — MirrorMaker2 Cross-Region ───────────────────────────────────────
resource "aws_s3_bucket" "results_sync" {
  bucket = "${var.cluster_name}-redpanda-results-sync"
  tags = {
    Environment        = var.environment
    Purpose            = "cross-region-results-sync"
    DataClassification = "results-only"
  }
}

resource "aws_s3_bucket_versioning" "results_sync" {
  bucket = aws_s3_bucket.results_sync.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results_sync" {
  bucket = aws_s3_bucket.results_sync.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# ── Security Group — Redpanda Brokers ────────────────────────────────────
resource "aws_security_group" "redpanda" {
  name        = "${var.cluster_name}-redpanda"
  description = "Redpanda broker security group"
  vpc_id      = var.vpc_id

  # Kafka API — من داخل الـ VPC فقط
  ingress {
    description = "Kafka API"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # Kafka Admin API
  ingress {
    description = "Kafka Admin"
    from_port   = 9644
    to_port     = 9644
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # Redpanda HTTP Proxy
  ingress {
    description = "HTTP Proxy"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # Schema Registry
  ingress {
    description = "Schema Registry"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  # Inter-broker communication
  ingress {
    description = "Inter-broker"
    from_port   = 33145
    to_port     = 33145
    protocol    = "tcp"
    self        = true
  }

  # Metrics
  ingress {
    description = "Prometheus metrics"
    from_port   = 9090
    to_port     = 9090
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

# ── IAM Role — Redpanda EC2 ──────────────────────────────────────────────
resource "aws_iam_role" "redpanda" {
  name = "${var.cluster_name}-redpanda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy" "redpanda_s3" {
  name = "redpanda-s3-access"
  role = aws_iam_role.redpanda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Tiered Storage
      {
        Sid    = "TieredStorage"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.tiered.arn,
          "${aws_s3_bucket.tiered.arn}/*",
        ]
      },
      # Results Sync
      {
        Sid    = "ResultsSync"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.results_sync.arn,
          "${aws_s3_bucket.results_sync.arn}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "redpanda" {
  name = "${var.cluster_name}-redpanda"
  role = aws_iam_role.redpanda.name
}

# ── Launch Template — Redpanda Broker ────────────────────────────────────
resource "aws_launch_template" "redpanda" {
  name_prefix   = "${var.cluster_name}-redpanda-"
  image_id      = data.aws_ami.al2023_arm64.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.redpanda.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.redpanda.id]
    delete_on_termination       = true
  }

  # NVMe optimized — im4gn has local NVMe storage
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 50
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    # IMDSv2 فقط — أكثر أماناً
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    cluster_name   = var.cluster_name
    broker_count   = var.broker_count
    tiered_bucket  = aws_s3_bucket.tiered.bucket
    aws_region     = data.aws_region.current.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.cluster_name}-redpanda"
      Environment = var.environment
      Role        = "redpanda-broker"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_region" "current" {}

# ── Auto Scaling Group — 3 Brokers عبر 3 AZs ────────────────────────────
resource "aws_autoscaling_group" "redpanda" {
  name                = "${var.cluster_name}-redpanda"
  desired_capacity    = var.broker_count
  min_size            = var.broker_count
  max_size            = var.broker_count + 1
  vpc_zone_identifier = var.private_subnet_ids

  launch_template {
    id      = aws_launch_template.redpanda.id
    version = "$Latest"
  }

  # broker واحد في كل AZ على الأقل
  instance_distribution_policy {
    availability_zone_distribution = true
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-redpanda"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────
output "tiered_storage_bucket" {
  value = aws_s3_bucket.tiered.bucket
}

output "results_sync_bucket" {
  value = aws_s3_bucket.results_sync.bucket
}

output "redpanda_role_arn" {
  value = aws_iam_role.redpanda.arn
}

output "broker_count" {
  value = var.broker_count
}

output "security_group_id" {
  value = aws_security_group.redpanda.id
}
