# ============================================================
# infra/terraform/environments/eu-west-1/main.tf
# FIX: إزالة backend "s3" {} — موجود بالفعل في backend.tf
# Terraform لا يسمح بـ backend configuration في أكثر من ملف
# ============================================================
terraform {
  # FIX: backend "s3" {} تم حذفه من هنا
  # الـ backend config موجود في backend.tf في نفس الـ directory
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
      Environment   = "production"
      Project       = "platform"
      Region        = var.aws_region
      ManagedBy     = "terraform"
      DataResidency = "eu"
    }
  }
}

module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-eu"
  cidr            = "10.2.0.0/16"
  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]
  public_subnets  = ["10.2.101.0/24", "10.2.102.0/24", "10.2.103.0/24"]
  cluster_name    = var.cluster_name
}

module "cluster" {
  source       = "../../modules/cluster"
  cluster_name = var.cluster_name
  environment  = "production"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
}

module "databases" {
  source       = "../../modules/databases"
  cluster_name = var.cluster_name
  environment  = "production"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
  multi_az     = true
}

module "redpanda" {
  source             = "../../modules/redpanda"
  cluster_name       = var.cluster_name
  environment        = "production"
  broker_count       = 3
  instance_type      = "im4gn.xlarge"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
}

module "vault" {
  source            = "../../modules/vault"
  cluster_name      = var.cluster_name
  environment       = "production"
  kms_key_id        = module.cluster.kms_key_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url
}

# ── Cross-Region Results Sync — EU Side ──────────────────
resource "aws_s3_bucket" "results_sync" {
  bucket = "platform-results-sync-eu-west-1"
  tags = {
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

resource "aws_s3_bucket_replication_configuration" "results_sync" {
  bucket = aws_s3_bucket.results_sync.id
  role   = aws_iam_role.replication.arn
  rule {
    id     = "sync-results-only"
    status = "Enabled"
    filter {
      prefix = "results/"
    }
    destination {
      bucket        = "arn:aws:s3:::platform-results-sync-us-east-1"
      storage_class = "STANDARD"
    }
  }
  depends_on = [aws_s3_bucket_versioning.results_sync]
}

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
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
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

# ── Outputs ───────────────────────────────────────────────
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
