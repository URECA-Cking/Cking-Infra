# 인증 정보가 로그에 남지 않도록 토큰·쿠키 헤더와 쿼리 문자열(OAuth 콜백의 code)을 가린다.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
}

# WAF가 계정 공용 정책(AWSWAF-LOGS)을 고치지 않도록 로그 그룹마다 정책을 둔다.
resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name = "aws-waf-logs-${var.name}"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.waf.arn}:*"
      Condition = {
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*" }
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  dynamic "redacted_fields" {
    for_each = ["authorization", "cookie", "x-cking-recommendation-key", "x-cking-gate"]

    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }

  redacted_fields {
    query_string {}
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
