resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = data.aws_security_group.alb.id
}

# 헬스체크·등록 해제 대기는 개발 앱 대상 그룹(dev-cking-app-tg)과 같다.
resource "aws_lb_target_group" "app" {
  name                 = "${var.env_name}-cking-app-tg"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 300

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 8080
}

resource "aws_lb_listener_rule" "app" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = [local.api_host]
    }
  }
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.api_host
  type    = "A"

  alias {
    name                   = data.aws_lb.main.dns_name
    zone_id                = data.aws_lb.main.zone_id
    evaluate_target_health = false
  }
}
