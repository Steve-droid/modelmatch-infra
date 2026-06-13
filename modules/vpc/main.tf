# Our own VPC module: a VPC across var.az_count AZs with one public + one private subnet per AZ,
# an IGW, EXACTLY ONE NAT gateway (the deliberate, HLD-documented egress SPOF — a 2nd NAT would
# ~double egress cost for no portfolio benefit), one shared private route table -> the single NAT,
# and a free S3 gateway endpoint that keeps S3 / ECR-layer / TF-state egress off the metered NAT.
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

# ---- Single NAT gateway (the egress SPOF) ------------------------------------
# One EIP + one NAT in the first public subnet. All private egress funnels through this one NAT;
# if its AZ fails, private-subnet egress (Bedrock calls, image pulls) stops. Deliberate cost call.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  # A NAT needs the IGW reachable before it can route; make the ordering explicit.
  depends_on = [aws_internet_gateway.this]
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

# ---- Private routing: one route table PER private subnet (per AZ) -> the single NAT ----
# One private RT per AZ even though there's a single NAT today (Steve's call). Route tables are free,
# and this is the forward-compatible layout: if we ever move to per-AZ NATs for HA, each AZ's RT just
# repoints to its local NAT with no restructuring. Today every per-AZ RT points at the one NAT.

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
  nat_gateway_id         = aws_nat_gateway.this.id
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
