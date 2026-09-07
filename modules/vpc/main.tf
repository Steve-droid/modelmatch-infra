# Our own VPC module: a VPC across var.az_count AZs with one public + one private subnet per AZ,
# an IGW, ONE NAT gateway PER AZ (P37, 2026-09-07 — replaced the single-NAT egress SPOF so an AZ loss
# leaves the surviving AZ's private egress intact), one private route table per AZ whose default
# route points at its OWN AZ's NAT, and a free S3 gateway endpoint that keeps S3 / ECR-layer /
# TF-state egress off the metered NATs.
#
# AZs are discovered (data source), never hardcoded ap-south-1a/b. CIDRs are carved from var.vpc_cidr
# with cidrsubnet() so there are no magic subnet numbers. default_tags (stack = platform) stamp the
# lifecycle/owner tags automatically; only Name + functional EKS tags are set per resource.

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # First var.az_count available AZs in the region (e.g. ap-south-1a, ap-south-1b).
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS nodes / private DNS need hostnames

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ---- Subnets -----------------------------------------------------------------
# Public subnets take cidrsubnet indexes 0..az_count-1; private take az_count..2*az_count-1,
# so the two ranges never overlap. With /16 + newbits 4 => /20s: public 10.0.0.0/20, 10.0.16.0/20;
# private 10.0.32.0/20, 10.0.48.0/20.

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, var.subnet_newbits, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    { Name = "${var.name_prefix}-public-${local.azs[count.index]}" },
    var.enable_eks_tags ? { "kubernetes.io/role/elb" = "1" } : {},
    var.public_subnet_extra_tags
  )
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, var.subnet_newbits, count.index + var.az_count)
  availability_zone = local.azs[count.index]

  tags = merge(
    { Name = "${var.name_prefix}-private-${local.azs[count.index]}" },
    var.enable_eks_tags ? { "kubernetes.io/role/internal-elb" = "1" } : {},
    var.private_subnet_extra_tags
  )
}

# ---- NAT gateways: one per AZ ------------------------------------------------
# One EIP + one NAT in EACH public subnet (index i = AZ i). Private egress from AZ i (Bedrock calls,
# image pulls, package fetches) leaves through NAT i, so losing one AZ — the P40 failover drill —
# does not take down the other AZ's egress. Cost: ~$0.045/h + $0.045/GB per NAT; the 2nd NAT is
# the price of removing the "egress SPOF" that the HLD listed as a limitation until P37.

resource "aws_eip" "nat" {
  count = var.az_count

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${local.azs[count.index]}"
  }
}

resource "aws_nat_gateway" "this" {
  count = var.az_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${local.azs[count.index]}"
  }

  # A NAT needs the IGW reachable before it can route; make the ordering explicit.
  depends_on = [aws_internet_gateway.this]
}

# P37 refactor: the original single EIP/NAT (no count) became element [0] of the per-AZ sets.
# `moved` makes Terraform follow the rename in state instead of destroying and recreating the
# AZ-a NAT (which would drop AZ-a egress for minutes and burn a new EIP). Declarative, reviewed in
# the PR, and replayed on any future rebuild — unlike a one-off `terraform state mv`.
moved {
  from = aws_eip.nat
  to   = aws_eip.nat[0]
}

moved {
  from = aws_nat_gateway.this
  to   = aws_nat_gateway.this[0]
}

# ---- Public routing: subnets -> IGW ------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- Private routing: one route table PER private subnet (per AZ) -> that AZ's NAT ----
# One private RT per AZ (Steve's call at P3, when a single NAT still served both). Route tables are
# free, and the layout paid off at P37: moving to per-AZ NATs was a one-line repoint of each RT's
# default route to its local NAT — no restructuring. RT i -> NAT i, both in AZ i.

resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${local.azs[count.index]}"
  }
}

resource "aws_route" "private_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---- S3 gateway endpoint (free) ----------------------------------------------
# Gateway endpoints attach to ROUTE TABLES (no ENI, no hourly charge). Associated with the private
# RTs only: that's where the NAT-cost saving comes from (private egress to S3, ECR layer pulls which
# are S3-backed, and TF state). Public-subnet S3 traffic already exits free via the IGW.
# NOTE: the ECR *API* (not layers) still needs the NAT — an interface endpoint for it is out of P3 scope.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-s3-endpoint"
  }
}
