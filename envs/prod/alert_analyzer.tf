# 경보 AI 진단(함수는 envs/dev/alert_analyzer.tf)이 운영 경보 주제를 구독한다. 진단은 운영 경보 채널 웹훅으로 남긴다.
# 운영 환경을 지우면 구독과 호출 허용도 같이 지워진다.

locals {
  alert_analyzer_function = "arn:aws:lambda:ap-northeast-2:551372961758:function:dev-cking-alert-analyzer"
}

resource "aws_lambda_permission" "alert_analyzer" {
  statement_id  = "sns-prod-alerts"
  action        = "lambda:InvokeFunction"
  function_name = local.alert_analyzer_function
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "alert_analyzer" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = local.alert_analyzer_function

  depends_on = [aws_lambda_permission.alert_analyzer]
}
