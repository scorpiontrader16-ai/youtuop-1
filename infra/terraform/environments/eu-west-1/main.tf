terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "production"
      Project     = "platform"
      Region      = "eu-west-1"
      ManagedBy   = "terraform"
      # Regional Silo — بيانات أوروبا تبقى في أوروبا (GDPR)
      DataResidency = "eu"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "cluster_name" {
  type    = string
  default = "platform-eu"
}

# ── VPC — EU Regional Silo ──────────────────────────────────────────────
# CIDR مختلف عن us-east-1 (10.0.0.0/16) لتجنب تعارض الـ VPC Peering
module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-eu"
  cidr            = "10.1.0.0/16"
  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  public_subnets  = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24"]
  cluster_name    = var.cluster_name
}

# ── EKS Cluster — EU ────────────────────────────────────────────────────
module "cluster" {
  source       = "../../modules/cluster"
  cluster_name = var.cluster_name
  environment  = "production"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
}

# ── Databases — EU Silo ─────────────────────────────────────────────────
# بيانات منفصلة تماماً — لا تشارك مع us-east-1
module "databases" {
  source       = "../../modules/databases"
  cluster_name = var.cluster_name
  environment  = "production"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
  multi_az     = true
}

# ── Redpanda — EU Silo ──────────────────────────────────────────────────
module "redpanda" {
  source       = "../../modules/redpanda"
  cluster_name = var.cluster_name
  environment  = "production"
  broker_count = 3
}

# ── Vault — EU ──────────────────────────────────────────────────────────
module "vault" {
  source            = "../../modules/vault"
  cluster_name      = var.cluster_name
  environment       = "production"
  kms_key_id        = module.cluster.kms_key_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url
}

# ── Cross-Region Sync — Results Only ───────────────────────────────────
# S3 bucket لمزامنة النتائج فقط (لا raw data) بين الـ regions
# هذا يطبق مبدأ M7: Cross-Region sync للنتائج فقط
resource "aws_s3_bucket" "results_sync" {
  bucket = "platform-results-sync-eu-west-1"
  tags = {
    Purpose = "cross-region-results-sync"
    # النتائج فقط — ليس البيانات الخام
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

# Replication من us-east-1 → eu-west-1 للنتائج فقط
resource "aws_s3_bucket_replication_configuration" "results_sync" {
  bucket = aws_s3_bucket.results_sync.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "sync-results-only"
    status = "Enabled"

    # فلتر — النتائج فقط (prefix: results/)
    filter {
      prefix = "results/"
    }

    destination {
      # الـ bucket في us-east-1
      bucket        = "arn:aws:s3:::platform-results-sync-us-east-1"
      storage_class = "STANDARD"
    }
  }

  depends_on = [aws_s3_bucket_versioning.results_sync]
}

# IAM Role للـ Replication
resource "aws_iam_role" "replication" {
  name = "platform-s3-replication-eu"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  name = "platform-s3-replication-eu-policy"
  role = aws_iam_role.replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.results_sync.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.results_sync.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "arn:aws:s3:::platform-results-sync-us-east-1/*"
      }
    ]
  })
}

# ── Outputs ─────────────────────────────────────────────────────────────
output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "eso_role_arn" {
  value = module.vault.eso_role_arn
}

output "results_sync_bucket" {
  value = aws_s3_bucket.results_sync.bucket
}
