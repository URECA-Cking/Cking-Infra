# 계정에 하나인 리소스는 envs/account가 만들고, 여기서는 이름으로 찾는다(운영·부하 테스트 스택과 같은 방식).

data "aws_route53_zone" "main" {
  name         = "cking.co.kr"
  private_zone = false
}

data "aws_acm_certificate" "alb" {
  domain      = "*.cking.co.kr"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_acm_certificate" "wildcard" {
  provider    = aws.us_east_1
  domain      = "*.cking.co.kr"
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}
