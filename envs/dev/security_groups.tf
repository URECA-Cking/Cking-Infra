# 들어오는 길은 보안 그룹 참조로만 연다: 인터넷 → ALB 80·443 → 앱 8080 → RDS 3306.
# 나가는 길은 ALB·앱 모두 전부 연다. ALB는 앱·관측 서버·부하 테스트 앱과 Google 로그인(OIDC) 토큰 주소로, 앱은 이미지·AWS API·외부 API로 나간다.

resource "aws_security_group" "alb" {
  name        = "dev-cking-alb-sg"
  description = "Dev ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "dev-cking-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = { https = 443, http = 80 }

  security_group_id = aws_security_group.alb.id
  description       = upper(each.key)
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Targets in VPC, OIDC token endpoint"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "app" {
  name        = "dev-cking-app-sg"
  description = "Dev app server"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "dev-cking-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Image pull, AWS APIs, external APIs, RDS, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db" {
  name        = "dev-cking-rds-sg"
  description = "Dev RDS"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "dev-cking-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from app server"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id
}
