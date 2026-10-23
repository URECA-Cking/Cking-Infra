# 경보 AI 진단. Grafana(분석용 SNS), CloudWatch(dev-cking-alerts), 운영 경보 주제(prod-cking-alerts, 구독은 envs/prod) 경보를 받아
# Claude가 런북대로 읽기 전용 조회를 하고 그 경보가 가는 Slack 채널(개발·운영 경보 채널 웹훅)에 제안을 남긴다. 조치는 사람이 한다.
# 개발 VPC에는 NAT가 없어 Lambda는 VPC 밖에 두고, 관측 서버 Prometheus·Loki 조회는 고정 SSM 문서로만 한다.
# 모델은 Claude API로 부른다. 이 계정은 Bedrock의 Anthropic 모델이 막혀 있다(403 not available for this account).
# 함수 코드는 alert-analyzer/ 배포 워크플로가 바꾸므로 Terraform은 비교하지 않는다. 처음 apply 전에 build.sh로 만든 묶음을
# s3://dev-cking-deploy-551372961758/alert-analyzer/initial.zip 에 올려 둔다.

locals {
  alert_analyzer_name = "dev-cking-alert-analyzer"
  alert_analyzer_arn  = "arn:aws:lambda:ap-northeast-2:551372961758:function:${local.alert_analyzer_name}"
}

# Grafana가 관측 서버 역할로 발행한다(observability.tf).
resource "aws_sns_topic" "alert_analysis" {
  name = "dev-cking-alert-analysis"
}

resource "aws_ssm_document" "observability_query" {
  name            = "dev-cking-observability-query"
  document_type   = "Command"
  document_format = "JSON"

  # 값은 정해진 문자만 허용해 셸에 그대로 들어가도 명령이 되지 않게 한다. 쿼리는 base64로 감싸 받는다.
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Read-only Prometheus/Loki query on the observability server"
    parameters = {
      kind    = { type = "String", allowedValues = ["prometheus", "prometheus_range", "loki"] }
      query   = { type = "String", allowedPattern = "^[A-Za-z0-9+/=]+$" }
      minutes = { type = "String", allowedPattern = "^[0-9]{1,5}$", default = "30" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "query"
      inputs = {
        timeoutSeconds = "90"
        runCommand     = ["python3 /opt/observability/query.py '{{ kind }}' '{{ query }}' '{{ minutes }}'"]
      }
    }]
  })
}

# 같은 경보 묶기와 하루 상한 기록. 기록은 만료 시각(expires_at)이 지나면 지워진다.
resource "aws_dynamodb_table" "alert_analyzer" {
  name         = local.alert_analyzer_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  attribute {
    name = "key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

resource "aws_cloudwatch_log_group" "alert_analyzer" {
  name              = "/aws/lambda/${local.alert_analyzer_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "alert_analyzer" {
  name = "${local.alert_analyzer_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 조회는 모두 읽기 전용이다. 서버 안 명령은 위 SSM 문서와 관측 서버로만 묶는다.
resource "aws_iam_role_policy" "alert_analyzer" {
  name = local.alert_analyzer_name
  role = aws_iam_role.alert_analyzer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.alert_analyzer.arn}:*"
      },
      {
        Sid      = "QueryObservability"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = [aws_instance.observability.arn, aws_ssm_document.observability_query.arn]
      },
      {
        Sid      = "ReadQueryResult"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      },
      {
        Sid    = "ReadParameters"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev/monitoring/ANTHROPIC_API_KEY",
          "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL",
          "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev/monitoring/SLACK_PROD_ALERT_WEBHOOK_URL",
        ]
      },
      {
        Sid    = "ReadAwsState"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeScalingActivities",
          "ec2:DescribeInstances",
          "ec2:GetConsoleOutput",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:DescribeAlarmHistory",
        ]
        Resource = "*"
      },
      {
        Sid      = "State"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.alert_analyzer.arn
      },
    ]
  })
}

# 경보 1건은 26~36초였다. 응답이 멈춘 호출이 실행 상한까지 가도 0.5GB×600초로 $0.004라 넉넉히 둔다.
# 동시에 여러 경보가 와도 두 개까지만 진단해 비용이 한꺼번에 늘지 않게 한다.
resource "aws_lambda_function" "alert_analyzer" {
  function_name = local.alert_analyzer_name
  role          = aws_iam_role.alert_analyzer.arn
  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "handler.handler"
  s3_bucket     = "dev-cking-deploy-551372961758"
  s3_key        = "alert-analyzer/initial.zip"
  memory_size   = 512
  timeout       = 600

  reserved_concurrent_executions = 2

  environment {
    variables = {
      STATE_TABLE               = aws_dynamodb_table.alert_analyzer.name
      DAILY_LIMIT               = "12"
      OBSERVABILITY_INSTANCE_ID = aws_instance.observability.id
      QUERY_DOCUMENT            = aws_ssm_document.observability_query.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.alert_analyzer, aws_iam_role_policy.alert_analyzer]

  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

# SNS 비동기 호출은 실패하면 두 번 더 실행되어 비용이 세 배가 된다. 다시 하지 않는다.
resource "aws_lambda_function_event_invoke_config" "alert_analyzer" {
  function_name                = aws_lambda_function.alert_analyzer.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 3600
}

locals {
  alert_analyzer_topics = {
    grafana    = aws_sns_topic.alert_analysis.arn
    cloudwatch = aws_sns_topic.alerts.arn
  }
}

resource "aws_lambda_permission" "alert_analyzer" {
  for_each = local.alert_analyzer_topics

  statement_id  = "sns-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert_analyzer.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = each.value
}

resource "aws_sns_topic_subscription" "alert_analyzer" {
  for_each = local.alert_analyzer_topics

  topic_arn = each.value
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alert_analyzer.arn
}

# Infra 저장소 CI가 alert-analyzer/를 묶어 올리고 함수 코드를 바꾼다(deploy-alert-analyzer.yml).
resource "aws_iam_role_policy" "alert_analyzer_deploy" {
  name = "${local.alert_analyzer_name}-deploy"
  role = aws_iam_role.infra_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # UpdateFunctionCode는 호출한 쪽 자격으로 S3 묶음을 읽는다.
      {
        Sid      = "Package"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.deploy_bucket_arn}/alert-analyzer/*"
      },
      {
        Sid      = "UpdateFunction"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration"]
        Resource = local.alert_analyzer_arn
      },
    ]
  })
}
