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



module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-staging"
  cidr            = "10.1.0.0/16"
  azs             = var.availability_zones
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]
  cluster_name    = var.cluster_name
}

module "cluster" {
  source       = "../../modules/cluster"
  cluster_name = var.cluster_name
  environment  = "staging"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
}

module "databases" {
  source       = "../../modules/databases"
  cluster_name = var.cluster_name
  environment  = "staging"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
  multi_az     = false
}

module "redpanda" {
  source             = "../../modules/redpanda"
  cluster_name       = var.cluster_name
  environment        = "staging"
  broker_count       = 1
  instance_type      = "im4gn.xlarge"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
}

module "vault" {
  source            = "../../modules/vault"
  cluster_name      = var.cluster_name
  environment       = "staging"
  kms_key_id        = module.cluster.kms_key_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url
}

output "eso_role_arn" {
  value = module.vault.eso_role_arn
}
