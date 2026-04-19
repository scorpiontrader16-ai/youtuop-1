# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/production/main.tf      ║
# ║  Status: ✏️ MODIFIED                                             ║
# ║  Fix F-TF01: replaced every hardcoded CIDR / count / type        ║
# ║              with the corresponding var.* reference               ║
# ║  Fix X-01:  added provider aws.eu_west_1 alias; replication      ║
# ║             resource now targets the correct destination region   ║
# ║  Fix X-04:  results_sync bucket name → var.results_sync_bucket   ║
# ║  Fix F-TF18: enable_mena_region wired into locals.enable_mena    ║
# ╚══════════════════════════════════════════════════════════════════╝

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

# ── Primary Region ────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "production"
      Project     = "platform"
      Region      = var.aws_region
      ManagedBy   = "terraform"
    }
  }
}

# ── EU West 1 — Postgres Cross-Region Replica Destination ────────────────
# X-01: aws_db_instance_automated_backups_replication must be created in
# the *destination* region (eu-west-1), not the source (us-east-1).
# The AWS API requires the replication resource to exist in the destination
# region. Without this alias the resource would be provisioned in us-east-1
# and the replica would either fail at apply time or produce a non-functional
# backup replication target.

provider "aws" {
  alias  = "eu_west_1"
  region = "eu-west-1"
  default_tags {
    tags = {
      Environment = "production"
      Project     = "platform"
      Region      = "eu-west-1"
      ManagedBy   = "terraform"
    }
  }
}

# ── M7 Stub — MENA Region Gate ───────────────────────────────────────────
# enable_mena_region is declared in variables.tf and set in tfvars.
# All future M7 resources gate on local.enable_mena via count or for_each.
# This local eliminates the dead-code state where the variable was declared
# but never referenced in any resource.

locals {
  enable_mena = var.enable_mena_region
}

# ── VPC ──────────────────────────────────────────────────────────────────
module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-prod"
  cidr            = var.vpc_cidr
  azs             = var.availability_zones
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
  cluster_name    = var.cluster_name
}

# ── EKS Cluster ──────────────────────────────────────────────────────────
module "cluster" {
  source                  = "../../modules/cluster"
  cluster_name            = var.cluster_name
  environment             = "production"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnet_ids
  # H-03: see var.eks_public_access_cidrs in variables.tf
  eks_public_access_cidrs = var.eks_public_access_cidrs
}

# ── Databases ─────────────────────────────────────────────────────────────
module "databases" {
  source            = "../../modules/databases"
  cluster_name      = var.cluster_name
  environment       = "production"
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = var.vpc_cidr
  subnet_ids        = module.vpc.private_subnet_ids
  multi_az          = true
  # F-TF05: explicit override — module default is db.t4g.medium (dev-safe)
  postgres_instance = "db.r8g.large"
  # H-04: see var.eks_node_cidr in variables.tf
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
  # X-04: bucket name from var.results_sync_bucket — no hardcoded string.
  # S3 bucket names are globally unique; hardcoding risks collision.
  bucket = var.results_sync_bucket
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

# ── Postgres Read Replica — eu-west-1 ────────────────────────────────────
# X-01: provider = aws.eu_west_1 is mandatory.
# This resource must be created in the destination region (eu-west-1) because
# it represents the *receiving* end of the backup replication stream.
# Without the provider alias this resource would be created in us-east-1
# which is the source region — AWS would reject this or create a no-op replica.

resource "aws_db_instance_automated_backups_replication" "postgres_eu" {
  provider               = aws.eu_west_1
  source_db_instance_arn = module.databases.postgres_arn
  retention_period       = var.postgres_replica_retention_days
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
