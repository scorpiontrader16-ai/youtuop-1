# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/environments/staging/terraform.tfvars║
# ║  Status: ✏️ MODIFIED                                             ║
# ║  Fix F-TF18: every variable declared in variables.tf is listed   ║
# ╚══════════════════════════════════════════════════════════════════╝

aws_region         = "us-east-1"
cluster_name       = "platform-staging"
availability_zones = ["us-east-1a", "us-east-1b"]

# ── Networking ────────────────────────────────────────────────────────────
vpc_cidr        = "10.1.0.0/16"
private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
public_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]

# ── EKS API Access ───────────────────────────────────────────────────────
# H-03: Replace with VPN/bastion CIDR when bastion host is provisioned
eks_public_access_cidrs = ["10.1.0.0/16"]

# ── Database Ingress ──────────────────────────────────────────────────────
# H-04: Tighten to EKS node subnet CIDR once node groups are stable
eks_node_cidr = "10.1.0.0/16"

# ── Redpanda ─────────────────────────────────────────────────────────────
redpanda_broker_count  = 1
redpanda_instance_type = "im4gn.xlarge"
