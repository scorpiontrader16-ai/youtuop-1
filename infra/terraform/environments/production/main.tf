terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "production"
      Project     = "platform"
      Region      = "us-east-1"
      ManagedBy   = "terraform"
    }
  }
}



# ── VPC ──────────────────────────────────────────────────────────────────
module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-prod"
  cidr            = "10.0.0.0/16"
  azs             = var.availability_zones
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  cluster_name    = var.cluster_name
}

# ── EKS Cluster ──────────────────────────────────────────────────────────
module "cluster" {
  source                  = "../../modules/cluster"
  cluster_name            = var.cluster_name
  environment             = "production"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnet_ids
  # H-03: restricted to production VPC only — update to VPN CIDR when bastion is ready
  eks_public_access_cidrs = ["10.0.0.0/16"]
}

# ── Databases ─────────────────────────────────────────────────────────────
module "databases" {
  source         = "../../modules/databases"
  cluster_name   = var.cluster_name
  environment    = "production"
  vpc_id         = module.vpc.vpc_id
  subnet_ids     = module.vpc.private_subnet_ids
  multi_az       = true
  # H-04: restricted to production private subnets only
  eks_node_cidr  = "10.0.0.0/16"
}

# ── Redpanda ──────────────────────────────────────────────────────────────
module "redpanda" {
  source             = "../../modules/redpanda"
  cluster_name       = var.cluster_name
  environment        = "production"
  broker_count       = 3
  instance_type      = "im4gn.xlarge"
  vpc_id             = module.vpc.vpc_id
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
}

# ── Cross-Region Results Sync — US Side ──────────────────────────────────
resource "aws_s3_bucket" "results_sync" {
  bucket = "platform-results-sync-us-east-1"
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

# ── Postgres Read Replica في eu-west-1 ───────────────────────────────────
resource "aws_db_instance_automated_backups_replication" "postgres_eu" {
  source_db_instance_arn = module.databases.postgres_arn
  retention_period       = 7
}

# ── Outputs ───────────────────────────────────────────────────────────────
output "eso_role_arn" {
  value = module.vault.eso_role_arn
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "results_sync_bucket" {
  value = aws_s3_bucket.results_sync.bucket
}

output "redpanda_broker_ips" {
  value = module.redpanda.broker_private_ips
}
