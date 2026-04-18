# ── Variables ────────────────────────────────────────────────────────────






# ── S3 Tiered Storage ────────────────────────────────────────────────────
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

resource "aws_s3_bucket_lifecycle_configuration" "tiered" {
  bucket = aws_s3_bucket.tiered.id
  rule {
    id     = "archive-old-segments"
    status = "Enabled"
    filter {}
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

# ── Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "redpanda" {
  name        = "${var.cluster_name}-redpanda"
  description = "Redpanda broker access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Kafka API from VPC"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "Redpanda Admin API from VPC"
    from_port   = 9644
    to_port     = 9644
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "Schema Registry from VPC"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  ingress {
    description = "Inter-broker communication"
    from_port   = 33145
    to_port     = 33145
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Environment = var.environment }
}

# ── IAM Role للـ EC2 ─────────────────────────────────────────────────────
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
  name = "redpanda-tiered-storage"
  role = aws_iam_role.redpanda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
  })
}

resource "aws_iam_instance_profile" "redpanda" {
  name = "${var.cluster_name}-redpanda"
  role = aws_iam_role.redpanda.name
}

# ── AMI — ARM64 ──────────────────────────────────────────────────────────
data "aws_ami" "redpanda" {
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
}

data "aws_region" "current" {}

# ── EC2 Instances — Redpanda Brokers ─────────────────────────────────────
resource "aws_instance" "redpanda" {
  count = var.broker_count

  ami           = data.aws_ami.redpanda.id
  instance_type = var.instance_type

  subnet_id              = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.redpanda.id]
  iam_instance_profile   = aws_iam_instance_profile.redpanda.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 100
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    broker_id             = count.index
    cluster_name          = var.cluster_name
    tiered_storage_bucket = aws_s3_bucket.tiered.bucket
    aws_region            = data.aws_region.current.name
  }))

  tags = {
    Name                 = "${var.cluster_name}-redpanda-${count.index}"
    Environment          = var.environment
    Role                 = "redpanda-broker"
    BrokerId             = count.index
    "redpanda:cluster"   = var.cluster_name
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

# ── MirrorMaker 2 Instance — Cross-Region Sync ───────────────────────────
resource "aws_instance" "mirrormaker2" {
  ami           = data.aws_ami.redpanda.id
  instance_type = "c7g.large"

  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.redpanda.id]
  iam_instance_profile   = aws_iam_instance_profile.redpanda.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name        = "${var.cluster_name}-mirrormaker2"
    Environment = var.environment
    Role        = "mirrormaker2"
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────
output "tiered_storage_bucket" {
  value = aws_s3_bucket.tiered.bucket
}

output "redpanda_role_arn" {
  value = aws_iam_role.redpanda.arn
}

output "broker_count" {
  value = var.broker_count
}

output "broker_private_ips" {
  value = aws_instance.redpanda[*].private_ip
}

output "broker_ids" {
  value = aws_instance.redpanda[*].id
}

output "security_group_id" {
  value = aws_security_group.redpanda.id
}
