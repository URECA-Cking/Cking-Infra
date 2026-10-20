# 관측 서버(개발 VPC)를 같이 쓰기 위한 피어링. 운영 서버의 수집기가 관측 서버의 쓰기 포트로 밀어 넣는다.
# 개발 VPC·라우팅 테이블은 콘솔이 관리하므로 경로만 추가하고, 개발 쪽에서는 운영 앱 서브넷만 보이게 한다.

data "aws_vpc" "dev" {
  tags = { Name = "dev-cking-vpc" }
}

data "aws_route_table" "dev_public" {
  vpc_id = data.aws_vpc.dev.id
  tags   = { Name = "dev-cking-rtb-public" }
}

data "aws_security_group" "observability" {
  vpc_id = data.aws_vpc.dev.id
  name   = "dev-cking-observability-sg"
}

resource "aws_vpc_peering_connection" "dev" {
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = data.aws_vpc.dev.id
  auto_accept = true
  tags        = { Name = "prod-cking-to-dev" }
}

resource "aws_route" "app_to_dev" {
  for_each = toset(local.zones)

  route_table_id            = aws_route_table.app[each.key].id
  destination_cidr_block    = data.aws_vpc.dev.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.dev.id
}

resource "aws_route" "dev_public_to_prod_app" {
  route_table_id            = data.aws_route_table.dev_public.id
  destination_cidr_block    = local.app_subnets_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.dev.id
}

resource "aws_vpc_security_group_ingress_rule" "observability_from_prod" {
  for_each = { metrics = 9009, logs = 3500 }

  security_group_id = data.aws_security_group.observability.id
  description       = "Prod Alloy ${each.key}"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = local.app_subnets_cidr
}
