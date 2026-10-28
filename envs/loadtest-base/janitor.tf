# 남은 부하 테스트 리소스 정리기. lt.sh가 destroy를 trap으로 걸어도 Mac이 꺼지면 지우지 못한다.
# cking:ttl-hours 태그가 붙은 서버·RDS가 그 시간을 넘기면 멈춘다(지우지 않는다). 기한은 envs/loadtest의 ttl_hours.
# 1시간마다 한 번이라 Lambda·스케줄러 무료 한도 안이다.

data "archive_file" "janitor" {
  type        = "zip"
  source_file = "${path.module}/janitor/janitor.py"
  output_path = "${path.module}/.build/janitor.zip"
}

resource "aws_iam_role" "janitor" {
  name = "loadtest-cking-janitor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "janitor_logs" {
  role       = aws_iam_role.janitor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "janitor" {
  name = "loadtest-cking-janitor"
  role = aws_iam_role.janitor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Find"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "rds:DescribeDBInstances"]
        Resource = "*"
      },
      {
        Sid       = "StopTaggedInstances"
        Effect    = "Allow"
        Action    = "ec2:StopInstances"
        Resource  = "arn:aws:ec2:ap-northeast-2:551372961758:instance/*"
        Condition = { StringLike = { "aws:ResourceTag/cking:ttl-hours" = "*" } }
      },
      {
        Sid       = "StopTaggedDatabases"
        Effect    = "Allow"
        Action    = "rds:StopDBInstance"
        Resource  = "arn:aws:rds:ap-northeast-2:551372961758:db:*"
        Condition = { StringLike = { "aws:ResourceTag/cking:ttl-hours" = "*" } }
      },
      {
        Sid      = "ReadWebhook"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.parameter_arn}/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL"
      }
    ]
  })
}

resource "aws_lambda_function" "janitor" {
  function_name    = "loadtest-cking-janitor"
  role             = aws_iam_role.janitor.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "janitor.handler"
  filename         = data.archive_file.janitor.output_path
  source_code_hash = data.archive_file.janitor.output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      SLACK_WEBHOOK_PARAMETER = "/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL"
    }
  }
}

resource "aws_cloudwatch_log_group" "janitor" {
  name              = "/aws/lambda/${aws_lambda_function.janitor.function_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "janitor_scheduler" {
  name = "loadtest-cking-janitor-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "janitor_scheduler" {
  name = "invoke-janitor"
  role = aws_iam_role.janitor_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.janitor.arn
    }]
  })
}

resource "aws_scheduler_schedule" "janitor" {
  name                = "loadtest-cking-janitor"
  schedule_expression = "rate(1 hour)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.janitor.arn
    role_arn = aws_iam_role.janitor_scheduler.arn
  }
}
