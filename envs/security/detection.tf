# GuardDuty 발견 중 심각도 7(높음) 이상만 운영 경보 채널로 보낸다. 낮은 것은 콘솔·Security Hub에서 모아 본다.
# 운영 경보 SNS의 발행 허용은 envs/prod/alarms.tf가 rule/cking-security-* 이름으로 준다.

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

data "aws_sns_topic" "prod_alerts" {
  name = "prod-cking-alerts"
}

resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name = "cking-security-guardduty-high"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 7] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high" {
  rule = aws_cloudwatch_event_rule.guardduty_high.name
  arn  = data.aws_sns_topic.prod_alerts.arn
}

resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "cking-account"
  type          = "ACCOUNT"
}
