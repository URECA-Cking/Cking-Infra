# 콘솔이 관리하는 기존 리소스. 읽기만 하고 변경하지 않는다.

data "aws_vpc" "main" {
  tags = {
    Name = "dev-cking-vpc"
  }
}

data "aws_subnet" "public_2b" {
  vpc_id = data.aws_vpc.main.id

  tags = {
    Name = "dev-cking-subnet-public2-ap-northeast-2b"
  }
}

data "aws_security_group" "app" {
  vpc_id = data.aws_vpc.main.id
  name   = "dev-cking-app-sg"
}

data "aws_security_group" "alb" {
  vpc_id = data.aws_vpc.main.id
  name   = "dev-cking-alb-sg"
}

data "aws_lb" "main" {
  name = "dev-cking-alb"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.main.arn
  port              = 443
}

data "aws_route53_zone" "main" {
  name         = "cking.co.kr"
  private_zone = false
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_s3_bucket" "frontend" {
  bucket = "dev-cking-frontend-551372961758"
}

data "aws_cloudfront_distribution" "frontend" {
  id = "E2NQPJU059830V"
}

data "aws_acm_certificate" "wildcard" {
  provider = aws.us_east_1
  domain   = "*.cking.co.kr"
  statuses = ["ISSUED"]
}

data "aws_instance" "app" {
  filter {
    name   = "tag:Name"
    values = ["dev-cking-app"]
  }
}

data "aws_ssm_parameter" "alert_email" {
  name = "/cking/dev/monitoring/ALERT_EMAIL"
}
