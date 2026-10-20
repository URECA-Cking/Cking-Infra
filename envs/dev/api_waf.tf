# 운영과 같은 규칙을 세기만 하며 팀 QA 요청으로 오탐을 확인한다. IP당 요청 상한은 로그로 IP별 요청 수를 잰 뒤 정한다.

module "api_waf" {
  source = "../../modules/api-waf"

  name               = "dev-cking-api"
  alb_arn            = data.aws_lb.main.arn
  api_host           = "dev-api.cking.co.kr"
  mode               = "count"
  log_retention_days = 14
}
