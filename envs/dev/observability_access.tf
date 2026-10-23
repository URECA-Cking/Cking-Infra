locals {
  grafana_host        = "monitoring.cking.co.kr"
  grafana_legacy_host = "dev-monitoring.cking.co.kr"
}

data "aws_ssm_parameter" "google_oauth_client_id" {
  name = "/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_ID"
}

data "aws_ssm_parameter" "google_oauth_client_secret" {
  name            = "/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_SECRET"
  with_decryption = true
}

resource "aws_vpc_security_group_ingress_rule" "observability_grafana_from_alb" {
  security_group_id            = aws_security_group.observability.id
  description                  = "Grafana from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = data.aws_security_group.alb.id
}

resource "aws_lb_target_group" "grafana" {
  name        = "dev-cking-grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "instance"

  health_check {
    path    = "/api/health"
    matcher = "200"
  }
}

resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = aws_instance.observability.id
  port             = 3000
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 100

  action {
    type  = "authenticate-oidc"
    order = 1

    authenticate_oidc {
      issuer                 = "https://accounts.google.com"
      authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"
      token_endpoint         = "https://oauth2.googleapis.com/token"
      user_info_endpoint     = "https://openidconnect.googleapis.com/v1/userinfo"
      client_id              = data.aws_ssm_parameter.google_oauth_client_id.value
      client_secret          = data.aws_ssm_parameter.google_oauth_client_secret.value
      scope                  = "openid email"
    }
  }

  action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    host_header {
      values = [local.grafana_host]
    }
  }
}

# 개발·운영을 함께 보므로 주소에서 dev-를 뺐다. 옛 주소는 북마크·지난 경보 링크를 위해 새 주소로 넘긴다
resource "aws_lb_listener_rule" "grafana_legacy_redirect" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 101

  action {
    type = "redirect"

    redirect {
      host        = local.grafana_host
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = [local.grafana_legacy_host]
    }
  }
}

moved {
  from = aws_route53_record.grafana
  to   = aws_route53_record.grafana["dev-monitoring.cking.co.kr"]
}

resource "aws_route53_record" "grafana" {
  for_each = toset([local.grafana_host, local.grafana_legacy_host])

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = data.aws_lb.main.dns_name
    zone_id                = data.aws_lb.main.zone_id
    evaluate_target_health = false
  }
}
