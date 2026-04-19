# ╔══════════════════════════════════════════════════════════════════╗
# ║  Full path: infra/terraform/modules/networking/main.tf           ║
# ║  Fix NAT-SPOF: one NAT gateway per AZ instead of single NAT     ║
# ║    Previous: single NAT in public[0] — entire cluster loses      ║
# ║    egress if AZ-0 fails. In production with 3 AZs this is a     ║
# ║    critical single point of failure.                              ║
# ║    Fix: one EIP + one NAT per AZ, one route table per AZ.        ║
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

# NAT-SPOF FIX: one EIP per AZ
# Previous: single aws_eip.nat + single aws_nat_gateway.main in public[0].
# If AZ-0 becomes unavailable, ALL private subnets lose internet egress.
# Fix: count = length(var.public_subnets) — one NAT gateway per public subnet/AZ.
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

# NAT-SPOF FIX: one private route table per AZ, each pointing to its own NAT.
# Previous: single route table shared across all AZs → single NAT dependency.
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

# NAT-SPOF FIX: each private subnet gets its own route table
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

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
