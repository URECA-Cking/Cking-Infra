# 경보 AI 진단(함수는 envs/dev/alert_analyzer.tf). 운영 경보 주제를 구독하고, 운영 CloudWatch 경보·서버 띄우기 실패의
# 진단은 아래 주제로 같은 Amazon Q 채널에 남긴다. 받는 경보 주제에 진단을 다시 보내면 함수가 그것을 또 받아 주제를 나눈다.
# 운영 환경을 지우면 구독과 호출 허용도 같이 지워진다.

locals {
  alert_analyzer_function = "arn:aws:lambda:ap-northeast-2:551372961758:function:dev-cking-alert-analyzer"
}

resource "aws_sns_topic" "ai_diagnosis" {
  name = "prod-cking-ai-diagnosis"
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
