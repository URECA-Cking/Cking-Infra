# 운영 API 입구. HTTPS만 받고, 설정은 개발 ALB와 같다(TLS 정책, /readyz 외부 차단, 헬스체크).
# 해제 대기는 앱 종료 대기(stop_grace_period 90초)와 맞춰, 서버를 교체할 때 진행 중인 요청을 끊지 않는다.

data "aws_acm_certificate" "wildcard" {
  domain   = "*.cking.co.kr"
  statuses = ["ISSUED"]
}

data "aws_route53_zone" "main" {
  name         = "cking.co.kr"
  private_zone = false
}

resource "aws_security_group" "alb" {
  name        = "prod-cking-alb-sg"
  description = "Prod ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "prod-cking-alb-sg" }
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

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "App servers"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "main" {
  name               = "prod-cking-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = [aws_subnet.this["public-2a"].id, aws_subnet.this["public-2b"].id]
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.this["alb_logs"].id
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.this]
}

resource "aws_lb_target_group" "app" {
  name                 = "prod-cking-app-tg"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 90

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn   = data.aws_acm_certificate.wildcard.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# 헬스체크 경로는 ALB만 쓴다. 외부 요청에는 앱 응답 형식과 같은 404를 돌려준다.
resource "aws_lb_listener_rule" "block_readyz" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1

  condition {
    path_pattern {
      values = ["/readyz"]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = jsonencode({ code = "RESOURCE_NOT_FOUND", message = "대상을 찾을 수 없습니다." })
    }
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.cking.co.kr"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false
  }
}

# 개발 ALB에서 세기만 하며 다듬은 규칙을 차단으로 쓴다. 운영 서버(NAT IP)의 요청은 규칙을 건너뛴다.
module "api_waf" {
  source = "../../modules/api-waf"

  name               = "prod-cking-api"
  alb_arn            = aws_lb.main.arn
  api_host           = "api.cking.co.kr"
  mode               = "block"
  allow_ip_cidrs     = [for ip in local.nat_public_ips : "${ip}/32"]
  log_retention_days = 14

  gate = var.gate_enabled ? { secret = data.aws_ssm_parameter.gate_secret.value, mode = "count" } : null
}
