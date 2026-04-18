# Variables extracted from main.tf
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
  type        = string
  description = "VPC ID من networking module"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs من networking module"
}

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
