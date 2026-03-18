terraform {
  backend "s3" {}
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
      ManagedBy   = "terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "platform-prod"
}

module "vpc" {
  source          = "../../modules/networking"
  name            = "platform-prod"
  cidr            = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  cluster_name    = var.cluster_name
}

module "cluster" {
  source       = "../../modules/cluster"
  cluster_name = var.cluster_name
  environment  = "production"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
}

module "vault" {
  source            = "../../modules/vault"
  cluster_name      = var.cluster_name
  environment       = "production"
  kms_key_id        = module.cluster.kms_key_id
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url
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
  source       = "../../modules/redpanda"
  cluster_name = var.cluster_name
  environment  = "production"
  broker_count = 3
}
