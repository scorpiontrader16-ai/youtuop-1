# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/eu-west-1/main.tf       ║
# ║  Fix F-TF01: all hardcoded values replaced with var.*            ║
# ║  Fix F-TF01-C: multi_az + postgres_instance → var.*              ║
# ║  Fix ARN-BUG: replication destination uses var.results_sync_     ║
# ║    bucket_us — removes hardcoded ARN in 2 places                 ║
# ║  Fix X-01: replication resource lives in eu-west-1 (destination) ║
# ║  Fix VAULT-REGION-BUG: aws_region passed to vault module         ║
# ║  Fix SG-BUG: vpc_cidr passed to redpanda module                  ║
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
# C-03: helm provider configured with EKS credentials via exec plugin.
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
  cluster_name    = var.cluster_name
}

# ── EKS Cluster ──────────────────────────────────────────────────────────
module "cluster" {
  source                          = "../../modules/cluster"
  cluster_name                    = var.cluster_name
  environment                     = "production"
  vpc_id                          = module.vpc.vpc_id
  subnet_ids                      = module.vpc.private_subnet_ids
  eks_public_access_cidrs         = var.eks_public_access_cidrs
  github_org                      = var.github_org
  github_repo                     = var.github_repo
  # C-01/C-02: false — production us-east-1 owns the account-global resources.
  create_account_global_resources = false
  # H-03: false — production us-east-1 trail already covers eu-west-1 events.
  cloudtrail_multi_region         = false
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
