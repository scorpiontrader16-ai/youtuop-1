# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/staging/main.tf         ║
# ║  Status: ✏️ MODIFIED                                             ║
# ║  Fix F-TF01: replaced every hardcoded CIDR / count / type        ║
# ║              with the corresponding var.* reference               ║
# ╚══════════════════════════════════════════════════════════════════╝

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
      Environment = "staging"
      Project     = "platform"
      ManagedBy   = "terraform"
    }
  }
}

# ── VPC ──────────────────────────────────────────────────────────────────
module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-staging"
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
  environment             = "staging"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.private_subnet_ids
  # H-03: see var.eks_public_access_cidrs in variables.tf
  eks_public_access_cidrs = var.eks_public_access_cidrs
}

# ── Databases ─────────────────────────────────────────────────────────────
module "databases" {
  source        = "../../modules/databases"
  cluster_name  = var.cluster_name
  environment   = "staging"
  vpc_id        = module.vpc.vpc_id
  vpc_cidr      = var.vpc_cidr
  subnet_ids    = module.vpc.private_subnet_ids
  # Staging does not require Multi-AZ — explicit override of production-safe default (true)
  multi_az      = false
  # H-04: see var.eks_node_cidr in variables.tf
  eks_node_cidr = var.eks_node_cidr
}

# ── Redpanda ──────────────────────────────────────────────────────────────
module "redpanda" {
  source             = "../../modules/redpanda"
  cluster_name       = var.cluster_name
  environment        = "staging"
  broker_count       = var.redpanda_broker_count
  instance_type      = var.redpanda_instance_type
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
}

# ── Vault ─────────────────────────────────────────────────────────────────
module "vault" {
  source            = "../../modules/vault"
  cluster_name      = var.cluster_name
  environment       = "staging"
  kms_key_id        = module.cluster.kms_key_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url
}

# ── Outputs ───────────────────────────────────────────────────────────────
output "eso_role_arn" {
  value = module.vault.eso_role_arn
}
