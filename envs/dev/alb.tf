# 개발 API 입구. 같은 ALB에 Grafana(observability_access.tf)와 부하 테스트 앱(envs/loadtest) 호스트 규칙이 붙는다.
# 헬스체크는 운영과 같이 관리 포트(8081)의 liveness로 앱 생존만 본다. 배포 확인은 서버 안의 deploy.sh가 /readyz로 한다.

locals {
  api_host       = "dev-api.cking.co.kr"
  not_found_body = jsonencode({ code = "RESOURCE_NOT_FOUND", message = "대상을 찾을 수 없습니다." })
}

resource "aws_lb" "main" {
  #checkov:skip=CKV_AWS_91:개발 ALB 접근 로그는 비용 구성으로 두지 않는다(envs/security/triage.tf accepted-dev, ELB.5)
  name               = "dev-cking-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = [aws_subnet.this["public_2a"].id, aws_subnet.this["public_2b"].id]
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name     = "dev-cking-app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    port                = "8081"
    path                = "/actuator/health/liveness"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 8080
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn   = data.aws_acm_certificate.alb.arn

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

# 헬스체크 경로는 인증 없이 응답하므로 외부에 열지 않는다. 앱 응답 형식과 같은 404를 돌려준다.
resource "aws_lb_listener_rule" "block_health" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1

  condition {
    path_pattern {
      values = ["/livez", "/readyz"]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = local.not_found_body
    }
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.api_host
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false
  }
}
