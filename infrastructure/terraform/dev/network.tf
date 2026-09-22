# ---------------------------------------------------------------- foundations

# Ask AWS which AZs this account can actually use, instead of hard-coding
# us-east-1a/b (AZ names differ per account, and some are not available).
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"

  # Two AZs: the ALB requires two, and RDS needs two for its subnet group.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # cidrsubnet("10.20.0.0/16", 8, 3) => "10.20.3.0/24"
  # Tiers are spaced 10 apart so there is room to grow inside each tier.
  public_cidrs = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]      # .0 .1
  app_cidrs    = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)] # .10 .11
  data_cidrs   = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 20)] # .20 .21
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both are required for RDS endpoints and VPC endpoints to resolve by name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

# The VPC's door to the internet. Free; you pay only for data transfer.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.name }
}

# -------------------------------------------------------------------- subnets

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Load balancer nodes get public IPs from AWS itself; nothing else lives here.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-app-${local.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "data" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-data-${local.azs[count.index]}", Tier = "data" }
}

# --------------------------------------------------------------- route tables

# Public: everything not local goes out through the Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# App: outbound only, and only when the NAT switch is on.
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-app" }
}

resource "aws_route" "app_nat" {
  count = var.enable_nat ? 1 : 0

  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

# Data: no route to the internet at all, in either direction. The database
# never needs one, so it never gets one.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-data" }
}

resource "aws_route_table_association" "data" {
  count          = length(aws_subnet.data)
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ---------------------------------------------------------------- NAT (costs)

# count = 0 or 1 is how Terraform does "create this only if".
resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id # NAT lives in a PUBLIC subnet
  tags          = { Name = local.name }

  depends_on = [aws_internet_gateway.main]
}

# ------------------------------------------------------------- S3 endpoint

# Free, and it keeps ECR image-layer downloads (which are stored in S3) off
# the NAT Gateway, where they would be billed per GB.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id, aws_route_table.data.id]

  tags = { Name = "${local.name}-s3" }
}
