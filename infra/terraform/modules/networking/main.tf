# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/networking/main.tf           ║
# ║  Fix NAT-SPOF: one NAT gateway per AZ instead of single NAT     ║
# ║  Fix HIGH-03: VPC Flow Logs added to CloudWatch                  ║
# ║    Financial platform requires network traffic logging for        ║
# ║    incident investigation + PCI-DSS / SOC2 compliance.           ║
# ╚══════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.9.0"
}

resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                        = var.name
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.name }
}

# NAT-SPOF FIX: one EIP + one NAT per AZ.
resource "aws_eip" "nat" {
  count      = length(var.public_subnets)
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${var.name}-nat-${count.index + 1}" }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnets)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${count.index + 1}" }
  depends_on    = [aws_internet_gateway.main]
}

# NAT-SPOF FIX: one private route table per AZ.
resource "aws_route_table" "private" {
  count  = length(var.private_subnets)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = { Name = "${var.name}-private-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── VPC Flow Logs ─────────────────────────────────────────────────────────
# HIGH-03 FIX: financial platform requires network traffic logging.
# Without flow logs: no visibility into traffic patterns, impossible to
# investigate security incidents, fails PCI-DSS requirement 10.2 and SOC2.
# count gate: can be disabled for staging cost saving via enable_flow_logs = false.

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/flow-logs/${var.name}"
  retention_in_days = var.flow_logs_retention_days
  tags              = { Name = "${var.name}-flow-logs" }
}

resource "aws_iam_role" "vpc_flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.name}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.name}-flow-logs" }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  name  = "${var.name}-vpc-flow-logs"
  role  = aws_iam_role.vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  count           = var.enable_flow_logs ? 1 : 0
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.vpc_flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs[0].arn

  tags = { Name = "${var.name}-flow-logs" }
}

# ── Outputs ──────────────────────────────────────────────────────────────
output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
