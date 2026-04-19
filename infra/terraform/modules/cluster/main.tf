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






# أضف متغير للـ CIDRs المسموح بها للوصول لـ EKS API
# غيّر القيمة دي لـ IP الخاص بـ VPN أو bastion host عندك

# ── EKS Cluster ──────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    # مقيّد بـ VPN/bastion IPs فقط — مش 0.0.0.0/0
    public_access_cidrs = var.eks_public_access_cidrs
  }

  # F-TF04: API mode enables EKS Access Entries — replaces legacy aws-auth ConfigMap.
  # bootstrap_cluster_creator_admin_permissions = false — no implicit admin.
  # All cluster access must be granted explicitly via aws_eks_access_entry resources.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  # F-TF04: EXTENDED support = 14 months per minor version vs 4 months standard.
  # Reduces forced upgrade pressure and emergency maintenance windows in production.
  upgrade_policy {
    support_type = "EXTENDED"
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
  ]
}

# ── Node Group — ARM64 ───────────────────────────────────────────────────
resource "aws_eks_node_group" "arm64" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-arm64"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = ["r8g.xlarge", "r8g.2xlarge"]
  ami_type       = "AL2023_ARM_64_STANDARD"

  scaling_config {
    desired_size = 3
    min_size     = 2
    max_size     = 20
  }

  update_config {
    max_unavailable_percentage = 25
  }

  labels = {
    "kubernetes.io/arch" = "arm64"
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
    Environment              = var.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policies,
  ]
}

# ── KMS ──────────────────────────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "EKS encryption - ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Environment = var.environment }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ── IAM — Cluster ────────────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ── IAM — Node ───────────────────────────────────────────────────────────
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  policy_arn = each.value
  role       = aws_iam_role.node.name
}

# ── OIDC — GitHub Actions ────────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "${var.cluster_name}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:sub" = "repo:scorpiontrader16-ai/AmniX-Finance:ref:refs/heads/main"
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ── OIDC — EKS ───────────────────────────────────────────────────────────
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# ── GuardDuty ────────────────────────────────────────────────────────────
resource "aws_guardduty_detector" "main" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = { Environment = var.environment }
}

# ── CloudTrail ───────────────────────────────────────────────────────────
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.cluster_name}-cloudtrail-logs"
  force_destroy = var.environment != "production"
  tags          = { Environment = var.environment }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.eks.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.cluster_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.eks.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"]
    }
  }

  tags = { Environment = var.environment }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ── S3 Public Access Block — Account Level ───────────────────────────────
resource "aws_s3_account_public_access_block" "main" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Helm — cert-manager ──────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }

  depends_on = [aws_eks_node_group.arm64]
}

# ── Helm — external-secrets ──────────────────────────────────────────────
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.13"
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [aws_eks_node_group.arm64]
}

# ── Outputs ──────────────────────────────────────────────────────────────
output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_ca_data" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "kms_key_id" {
  value = aws_kms_key.eks.arn
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.main.id
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.bucket
}
