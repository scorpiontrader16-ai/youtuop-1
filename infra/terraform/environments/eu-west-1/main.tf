# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/main.tf       ║
# ║  Fix F-TF01: all hardcoded values replaced with var.*            ║
# ║  Fix F-TF01-C: multi_az + postgres_instance → var.*              ║
# ║  Fix ARN-BUG: replication destination uses var.results_sync_     ║
# ║    bucket_us — removes hardcoded ARN in 2 places                 ║
# ║  Fix VAULT-REGION-BUG: aws_region passed to vault module         ║
# ║  Fix SG-BUG: vpc_cidr passed to redpanda module                  ║
# ║  Fix HIGH-01: results_sync S3 public access block added          ║
# ║  Fix MEDIUM-05: results_sync S3 lifecycle policy added           ║
# ╚══════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.9.0"
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


# ── Helm Provider ─────────────────────────────────────────────────────────
# Required by cluster module (cert-manager + external-secrets helm_release).
# Uses EKS exec plugin — requires aws CLI in CI/CD execution environment.
# Two-phase apply: see infra/terraform/environments/APPLY_ORDER.md
provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_ca_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "tls" {}

# ── VPC ──────────────────────────────────────────────────────────────────
module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-eu"
  cidr            = var.vpc_cidr
  azs             = var.availability_zones
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
  cluster_name             = var.cluster_name
  enable_flow_logs         = true
  flow_logs_retention_days = 90
}

# ── EKS Cluster ──────────────────────────────────────────────────────────
# create_account_global_resources = false — production us-east-1 owns account-global resources.
# cloudtrail_multi_region = false — production us-east-1 trail already covers eu-west-1 events.
module "cluster" {
  source                          = "../../modules/cluster"
  cluster_name                    = var.cluster_name
  environment                     = "production"
  vpc_id                          = module.vpc.vpc_id
  subnet_ids                      = module.vpc.private_subnet_ids
  eks_public_access_cidrs         = var.eks_public_access_cidrs
  github_org                      = var.github_org
  github_repo                     = var.github_repo
  create_account_global_resources = var.create_account_global_resources
  cloudtrail_multi_region         = var.cloudtrail_multi_region
}

# ── Databases ─────────────────────────────────────────────────────────────
module "databases" {
  source            = "../../modules/databases"
  cluster_name      = var.cluster_name
  environment       = "production"
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = var.vpc_cidr
  subnet_ids        = module.vpc.private_subnet_ids
  multi_az          = var.multi_az
  postgres_instance = var.postgres_instance
  eks_node_cidr     = var.eks_node_cidr
}

# ── Redpanda ──────────────────────────────────────────────────────────────
module "redpanda" {
  source             = "../../modules/redpanda"
  cluster_name       = var.cluster_name
  environment        = "production"
  broker_count       = var.redpanda_broker_count
  instance_type      = var.redpanda_instance_type
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
}

# ── Vault ─────────────────────────────────────────────────────────────────
module "vault" {
  source            = "../../modules/vault"
  cluster_name      = var.cluster_name
  environment       = "production"
  kms_key_id        = module.cluster.kms_key_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url
  aws_region        = var.aws_region
}

# ── Cross-Region Results Sync — EU Side ──────────────────────────────────
resource "aws_s3_bucket" "results_sync" {
  bucket = var.results_sync_bucket_eu
  tags = {
    Purpose            = "cross-region-results-sync"
    DataClassification = "results-only"
  }
}

# HIGH-01 FIX: block all public access — financial data must never be public.
resource "aws_s3_bucket_public_access_block" "results_sync" {
  bucket                  = aws_s3_bucket.results_sync.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
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

# MEDIUM-05 FIX: lifecycle policy for results data retention.
resource "aws_s3_bucket_lifecycle_configuration" "results_sync" {
  bucket = aws_s3_bucket.results_sync.id

  rule {
    id     = "results-retention"
    status = "Enabled"
    filter {}

    transition {
      days          = var.results_sync_standard_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.results_sync_glacier_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.results_sync_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.results_sync]
}

# ARN-BUG FIX: destination bucket ARN built from var.results_sync_bucket_us.
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
      bucket        = "arn:aws:s3:::${var.results_sync_bucket_us}"
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
          "s3:GetObjectVersionTagging",
        ]
        Resource = "${aws_s3_bucket.results_sync.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
        ]
        Resource = "arn:aws:s3:::${var.results_sync_bucket_us}/*"
      }
    ]
  })
}

# ── Postgres Cross-Region Backup Replication ──────────────────────────────
resource "aws_db_instance_automated_backups_replication" "postgres_us" {
  source_db_instance_arn = var.source_db_instance_arn
  retention_period       = var.postgres_replica_retention_days
}

# ── Outputs ───────────────────────────────────────────────────────────────
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
