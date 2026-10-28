# 운영 VPC. AZ 두 곳에 퍼블릭(ALB·NAT), 프라이빗 앱(서버), 프라이빗 데이터(RDS·ElastiCache) 서브넷을 둔다.
# NAT는 AZ마다 두어 한 AZ가 멈춰도 다른 AZ 서버의 외부 호출(배포, AI API)이 이어진다. 방식(관리형 게이트웨이·인스턴스)은 nat.tf의 nat_mode로 고른다.

locals {
  zones = ["2a", "2b"]

  subnets = {
    public-2a = { tier = "public", zone = "2a", cidr = "10.1.0.0/20" }
    public-2b = { tier = "public", zone = "2b", cidr = "10.1.16.0/20" }
    app-2a    = { tier = "app", zone = "2a", cidr = "10.1.32.0/20" }
    app-2b    = { tier = "app", zone = "2b", cidr = "10.1.48.0/20" }
    data-2a   = { tier = "data", zone = "2a", cidr = "10.1.64.0/20" }
    data-2b   = { tier = "data", zone = "2b", cidr = "10.1.80.0/20" }
  }

  app_subnets_cidr = "10.1.32.0/19"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "prod-cking-vpc" }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = "ap-northeast-${each.value.zone}"
  tags              = { Name = "prod-cking-subnet-${each.key}", Tier = each.value.tier }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "prod-cking-igw" }
}

resource "aws_eip" "nat" {
  for_each = var.nat_mode == "gateway" ? toset(local.zones) : toset([])

  domain = "vpc"
  tags   = { Name = "prod-cking-nat-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each = var.nat_mode == "gateway" ? toset(local.zones) : toset([])

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this["public-${each.key}"].id
  tags          = { Name = "prod-cking-nat-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "prod-cking-rtb-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = toset(local.zones)

  subnet_id      = aws_subnet.this["public-${each.key}"].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  for_each = toset(local.zones)

  vpc_id = aws_vpc.main.id
  tags   = { Name = "prod-cking-rtb-app-${each.key}" }
}

resource "aws_route" "app_internet" {
  for_each = toset(local.zones)

  route_table_id         = aws_route_table.app[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.nat_mode == "gateway" ? aws_nat_gateway.this[each.key].id : null
  network_interface_id   = var.nat_mode == "instance" ? aws_instance.nat[each.key].primary_network_interface_id : null
}

resource "aws_route_table_association" "app" {
  for_each = toset(local.zones)

  subnet_id      = aws_subnet.this["app-${each.key}"].id
  route_table_id = aws_route_table.app[each.key].id
}

# 데이터 서브넷은 VPC 안에서만 통신한다.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "prod-cking-rtb-data" }
}

resource "aws_route_table_association" "data" {
  for_each = toset(local.zones)

  subnet_id      = aws_subnet.this["data-${each.key}"].id
  route_table_id = aws_route_table.data.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.app : rt.id]
  tags              = { Name = "prod-cking-s3" }
}
