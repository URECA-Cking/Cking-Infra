# deploy.sh가 읽는 /cking/<환경>/ 값 중 비밀이 아닌 것만 여기서 만든다.
# 비밀값(DB_PASSWORD, JWT_SECRET, ADMIN_ACCOUNT_LOGIN_ID, ADMIN_ACCOUNT_PASSWORD, DOCS_USERNAME, DOCS_PASSWORD)은 apply 전에 직접 넣는다.

locals {
  # 부하 테스트 범위 밖 기능(로그인, 외부 API)의 키. deploy.sh 필수 목록이라 값만 채운다.
  unused_parameters = [
    "OAUTH_GOOGLE_CLIENT_ID",
    "OAUTH_GOOGLE_CLIENT_SECRET",
    "OAUTH_KAKAO_CLIENT_ID",
    "OAUTH_KAKAO_CLIENT_SECRET",
    "SUBSCRIPTION_GEMINI_API_KEY",
    "GEMINI_API_KEY",
    "OPENAI_API_KEY",
  ]
}

resource "aws_ssm_parameter" "db_host" {
  name  = "/cking/${var.env_name}/DB_HOST"
  type  = "String"
  value = aws_db_instance.main.address
}

resource "aws_ssm_parameter" "db_username" {
  name  = "/cking/${var.env_name}/DB_USERNAME"
  type  = "String"
  value = aws_db_instance.main.username
}

resource "aws_ssm_parameter" "unused" {
  for_each = toset(local.unused_parameters)

  name  = "/cking/${var.env_name}/${each.value}"
  type  = "String"
  value = "${var.env_name}-unused"
}
