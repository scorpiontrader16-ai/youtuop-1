# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/vault/main.tf                ║
# ║  Fix VAULT-REGION-BUG: region = var.aws_region                   ║
# ║  Fix F-TF01-B: vault_version + vault_ha_replicas → var.*         ║
# ║  Fix H-05: ec2 vault role removed — all policies on vault_irsa   ║
# ║  Fix HIGH-04: added timeout=600 + atomic=true + wait=true        ║
# ║    Vault HA Raft init takes >5min default timeout → apply fails  ║
# ║    atomic=true ensures full rollback on failure                   ║
# ║  Fix MEDIUM-01: removed duplicate vault_role_arn output          ║
# ║    vault_irsa_role_arn is the canonical output name              ║
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

# HIGH-04 FIX: timeout + atomic + wait added.
# Vault HA with Raft consensus requires all 3 replicas to elect a leader
# before the Helm release is considered ready. This takes > 5 minutes
# (the Helm default timeout), causing apply to fail even though Vault
# is healthy. timeout=600 (10 min) gives Raft enough time to converge.
# atomic=true: if deploy fails, Helm rolls back completely — no partial state.
# wait=true: Terraform waits for all pods Ready before marking success.
resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = var.vault_version
  namespace        = "vault"
  create_namespace = true
  timeout          = 600
  atomic           = true
  wait             = true

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

# ── Outputs ──────────────────────────────────────────────────────────────
# MEDIUM-01 FIX: removed duplicate vault_role_arn output.
# vault_irsa_role_arn is the canonical name — use it for all references.
# vault_role_arn was an alias pointing to the same value — dead duplicate.
output "vault_irsa_role_arn" {
  value       = aws_iam_role.vault_irsa.arn
  description = "IAM role ARN for Vault IRSA — use this in all module references."
}

output "vault_storage_bucket" {
  value = aws_s3_bucket.vault.bucket
}

output "eso_role_arn" {
  value = aws_iam_role.eso.arn
}
