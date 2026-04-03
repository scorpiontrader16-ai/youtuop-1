variable "cluster_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "kms_key_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "namespace" {
  type    = string
  default = "platform"
}

# H-05: ec2-based vault IAM role removed — all policies migrated to vault_irsa (OIDC)
# This eliminates the ec2 principal which allowed any EC2 instance to assume the role

resource "aws_iam_role_policy" "vault_kms" {
  name = "vault-kms-unseal"
  # H-05: migrated from ec2 vault role to OIDC vault_irsa role
  role = aws_iam_role.vault_irsa.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]
      Resource = var.kms_key_id
    }]
  })
}

resource "aws_s3_bucket" "vault" {
  bucket = "${var.cluster_name}-vault-storage"
  tags   = { Environment = var.environment }
}

resource "aws_s3_bucket_versioning" "vault" {
  bucket = aws_s3_bucket.vault.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault" {
  bucket = aws_s3_bucket.vault.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_id
    }
  }
}

resource "aws_iam_role_policy" "vault_s3" {
  name = "vault-s3"
  # H-05: migrated from ec2 vault role to OIDC vault_irsa role
  role = aws_iam_role.vault_irsa.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.vault.arn,
        "${aws_s3_bucket.vault.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_role" "vault_irsa" {
  name = "${var.cluster_name}-vault-irsa"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:vault:vault"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = { Environment = var.environment }
}

# vault_irsa_kms attachment removed — vault_kms policy now attached directly
# to vault_irsa role (H-05 fix: removed ec2 principal, using OIDC only)

resource "aws_iam_role" "eso" {
  name = "${var.cluster_name}-eso"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy" "eso_secrets" {
  name = "eso-secrets-manager"
  role = aws_iam_role.eso.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:platform/*"
      }
      # H-06: ListSecrets on Resource:* removed — ESO uses explicit platform/* paths
      # and does not require account-wide list permissions
    ]
  })
}

resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.27.0"
  namespace        = "vault"
  create_namespace = true

  values = [
    yamlencode({
      server = {
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.vault_irsa.arn
          }
        }
        ha = {
          enabled  = true
          replicas = 3
          raft = {
            enabled = true
          }
        }
        extraEnvironmentVars = {
          VAULT_SEAL_TYPE          = "awskms"
          VAULT_AWSKMS_SEAL_KEY_ID = var.kms_key_id
        }
        storage = {
          s3 = {
            bucket = aws_s3_bucket.vault.bucket
            region = "us-east-1"
          }
        }
      }
      injector = {
        enabled = false
      }
    })
  ]

  depends_on = [aws_iam_role.vault_irsa]
}

output "vault_role_arn" {
  # H-05: updated to vault_irsa — ec2-based vault role removed
  value = aws_iam_role.vault_irsa.arn
}

output "vault_storage_bucket" {
  value = aws_s3_bucket.vault.bucket
}

output "vault_irsa_role_arn" {
  value = aws_iam_role.vault_irsa.arn
}

output "eso_role_arn" {
  value = aws_iam_role.eso.arn
}
