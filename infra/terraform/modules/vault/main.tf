# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/vault/main.tf                ║
# ║  Fix VAULT-REGION-BUG: region = var.aws_region (was "us-east-1")║
# ║  Fix F-TF01-B: vault_version + vault_ha_replicas → var.*         ║
# ║  H-05: ec2 vault role removed — all policies on vault_irsa OIDC  ║
# ╚══════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.9.0"
}


resource "aws_iam_role_policy" "vault_kms" {
  name = "vault-kms-unseal"
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
    ]
  })
}

# VAULT-REGION-BUG FIX: storage.s3.region now uses var.aws_region.
# Previous hardcoded "us-east-1" caused Vault to fail in eu-west-1 because
# the S3 bucket is created in the provider region (eu-west-1) but Vault
# attempted to connect to it via the us-east-1 endpoint.
# F-TF01-B: version → var.vault_version, replicas → var.vault_ha_replicas
resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = var.vault_version
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
          replicas = var.vault_ha_replicas
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
            region = var.aws_region
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
