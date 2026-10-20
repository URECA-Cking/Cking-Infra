# 서버 보안 그룹은 데이터 계층이 참조하므로 여기서 먼저 만든다. ALB에서 앱으로 들어오는 규칙은 앱 계층에서 더한다.

resource "aws_security_group" "app" {
  name        = "prod-cking-app-sg"
  description = "Prod app servers"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "prod-cking-app-sg" }
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Image pull, AWS APIs, external APIs, data, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# 감시용 서버는 Redis 지표 수집과, 사람이 Mac에서 SSM 포트 포워딩으로 RDS에 들어가는 경유지로 쓴다.
resource "aws_security_group" "monitor" {
  name        = "prod-cking-monitor-sg"
  description = "Prod monitor server"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "prod-cking-monitor-sg" }
}

resource "aws_vpc_security_group_egress_rule" "monitor_all" {
  security_group_id = aws_security_group.monitor.id
  description       = "Image pull, AWS APIs, data, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db" {
  name        = "prod-cking-rds-sg"
  description = "Prod RDS"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "prod-cking-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db" {
  for_each = { app = aws_security_group.app.id, monitor = aws_security_group.monitor.id }

  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = each.value
}

resource "aws_security_group" "redis" {
  name        = "prod-cking-redis-sg"
  description = "Prod ElastiCache"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "prod-cking-redis-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "redis" {
  for_each = { app = aws_security_group.app.id, monitor = aws_security_group.monitor.id }

  security_group_id            = aws_security_group.redis.id
  description                  = "Valkey from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = each.value
}
