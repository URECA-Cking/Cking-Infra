# GitHub Actions 토큰을 믿는 OIDC 공급자. 계정에 하나이며 저장소마다 역할의 신뢰 조건(sub)으로 나눈다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
