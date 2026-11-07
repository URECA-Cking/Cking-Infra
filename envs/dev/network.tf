# 개발 VPC. 서버는 퍼블릭 서브넷에 공인 IP로 두고(NAT 없음), RDS만 프라이빗 서브넷에 둔다.
# 이름은 운영(peering.tf)·부하 테스트·보안 기준선 스택이 이름표로 찾으므로 바꾸지 않는다.
# 퍼블릭 경로 테이블에는 운영 스택이 피어링 경로를 더하므로 경로를 aws_route로 따로 둔다.

locals {
  subnets = {
    public_2a  = { name = "public1-ap-northeast-2a", zone = "ap-northeast-2a", cidr = "10.0.0.0/20" }
    public_2b  = { name = "public2-ap-northeast-2b", zone = "ap-northeast-2b", cidr = "10.0.16.0/20" }
    private_2a = { name = "private1-ap-northeast-2a", zone = "ap-northeast-2a", cidr = "10.0.128.0/20" }
    private_2b = { name = "private2-ap-northeast-2b", zone = "ap-northeast-2b", cidr = "10.0.144.0/20" }
  }

  private_subnets = ["private_2a", "private_2b"]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "dev-cking-vpc" }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.zone
  tags              = { Name = "dev-cking-subnet-${each.value.name}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-cking-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-cking-rtb-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = toset(["public_2a", "public_2b"])

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = toset(local.private_subnets)

  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-cking-rtb-${local.subnets[each.key].name}" }
}

resource "aws_route_table_association" "private" {
  for_each = toset(local.private_subnets)

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# 과금이 없어 두지만 프라이빗 경로 테이블에만 붙어 있어, 퍼블릭 서브넷 서버의 S3 요청은 인터넷 게이트웨이로 나간다.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]
  tags              = { Name = "dev-cking-vpce-s3" }
}
