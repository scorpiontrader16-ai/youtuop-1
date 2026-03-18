variable "cluster_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "kms_key_id" {
  type = string
}

resource "aws_iam_role" "vault" {
  name = "${var.cluster_name}-vault"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Environment = var.environment }
}

resource "aws_iam_role_policy" "vault_kms" {
  name = "vault-kms-unseal"
  role = aws_iam_role.vault.id
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
  role = aws_iam_role.vault.id
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

output "vault_role_arn" {
  value = aws_iam_role.vault.arn
}

output "vault_storage_bucket" {
  value = aws_s3_bucket.vault.bucket
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

# IRSA role for Vault
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

resource "aws_iam_role_policy_attachment" "vault_irsa_kms" {
  role       = aws_iam_role.vault_irsa.name
  policy_arn = aws_iam_role_policy.vault_kms.id
}

# Vault Helm chart
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
          VAULT_SEAL_TYPE       = "awskms"
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

output "vault_irsa_role_arn" {
  value = aws_iam_role.vault_irsa.arn
}
