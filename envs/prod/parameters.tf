# deploy.sh와 감시용 서버가 읽는 값 중 비밀이 아닌 것만 여기서 만든다.
# 비밀값(DB_PASSWORD, REDIS_PASSWORD 등)은 사람이 SecureString으로 직접 넣는다(README 운영 환경 절차).

locals {
  db_app_username = "cking_app"

  plain_parameters = {
    "/cking/prod/DB_HOST"                 = aws_db_instance.main.address
    "/cking/prod/DB_USERNAME"             = local.db_app_username
    "/cking/prod/REDIS_HOST"              = aws_elasticache_replication_group.main.primary_endpoint_address
    "/cking/prod/REDIS_USERNAME"          = aws_elasticache_user.app.user_name
    "/cking/prod-monitor/REDIS_HOST"      = aws_elasticache_replication_group.main.primary_endpoint_address
    "/cking/prod-monitor/REDIS_USERNAME"  = aws_elasticache_user.monitor.user_name
    "/cking/prod/COMMENT_FILTER_BASE_URL" = trimsuffix(aws_lambda_function_url.comment_filter.function_url, "/")
  }
}

resource "aws_ssm_parameter" "plain" {
  for_each = local.plain_parameters

  name  = each.key
  type  = "String"
  value = each.value
}
