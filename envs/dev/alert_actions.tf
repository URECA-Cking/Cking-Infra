# 경보 AI 진단의 조치 승인 버튼. 진단이 "지금 조치 필요"로 런북 조치를 제안하면 메시지에 버튼이 붙고,
# 승인자가 누르면 승인 함수(함수 URL, Slack 서명 검증)가 실행 함수를 부른다. 실행 함수는 조치마다 그 API·그 대상만 허용한다.
# 조치 목록과 실행 직전 검사는 alert-analyzer/actions.py.

locals {
  alert_approvals_name = "dev-cking-alert-approvals"
  alert_executor_name  = "dev-cking-alert-executor"

  # 진단 메시지를 올리는 채널(봇 ID cking-ai를 초대해 둔다)과 버튼을 누를 수 있는 Slack 멤버
  alert_channels         = { dev = "C0CA27W8N1F", prod = "C0CAXUX1FKN" }
  alert_action_approvers = ["U0C9V1RMCS1"]

  alert_parameter_arn = "arn:aws:ssm:ap-northeast-2:551372961758:parameter"
  prod_deploy_bucket  = "arn:aws:s3:::prod-cking-deploy-551372961758-ap-northeast-2-an"
  asg_arn_prefix      = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName"

  # 진단(제안 때)과 실행 함수(실행 직전)가 같은 검사를 한다
  alert_action_reads = [
    {
      Sid    = "ReadActionState"
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeInstanceRefreshes",
        "elasticache:DescribeReplicationGroups",
        "ec2:DescribeInstanceStatus",
      ]
      Resource = "*"
    },
    {
      Sid      = "ReadFilterConcurrency"
      Effect   = "Allow"
      Action   = "lambda:GetFunctionConcurrency"
      Resource = [aws_lambda_function.comment_filter.arn, "arn:aws:lambda:ap-northeast-2:551372961758:function:prod-cking-comment-filter"]
    },
    {
      Sid       = "ListReleases"
      Effect    = "Allow"
      Action    = "s3:ListBucket"
      Resource  = [local.deploy_bucket_arn, local.prod_deploy_bucket]
      Condition = { StringLike = { "s3:prefix" = ["releases/*"] } }
    },
  ]
}

resource "aws_ssm_parameter" "alert_action_approvers" {
  name  = "/cking/dev/monitoring/AI_ACTION_APPROVERS"
  type  = "StringList"
  value = join(",", local.alert_action_approvers)
}

# 서버 안 조치는 고정 명령 SSM 문서로만 한다(런북 cking-stream-stopped, cking-redis-rejected, deploy-failed).
resource "aws_ssm_document" "dev_app_restart" {
  name            = "dev-cking-app-restart"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Restart the dev app container"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "restart"
      inputs = {
        timeoutSeconds = "180"
        runCommand     = ["docker restart cking-app", "docker ps --filter name=cking-app"]
      }
    }]
  })
}

resource "aws_ssm_document" "dev_redis_maxmemory" {
  name            = "dev-cking-redis-maxmemory"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Raise dev Redis maxmemory to 384mb until the container restarts"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "raise"
      inputs = {
        timeoutSeconds = "60"
        runCommand = [
          "current=$(docker exec cking-redis redis-cli CONFIG GET maxmemory | tail -n 1)",
          "if [ \"$current\" -ge 402653184 ]; then echo \"already $current\"; else docker exec cking-redis redis-cli CONFIG SET maxmemory 384mb; fi",
          "docker exec cking-redis redis-cli CONFIG GET maxmemory",
        ]
      }
    }]
  })
}

resource "aws_ssm_document" "dev_app_rollback" {
  name            = "dev-cking-app-rollback"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Roll the dev app back to an earlier release tag"
    parameters = {
      tag = { type = "String", allowedPattern = "^[0-9]{14}-[0-9a-f]{7}$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "rollback"
      inputs = {
        timeoutSeconds = "900"
        runCommand = [
          "aws s3 cp --region ap-northeast-2 \"s3://dev-cking-deploy-551372961758/releases/{{ tag }}/deploy.sh\" /opt/cking/deploy.sh",
          "bash /opt/cking/deploy.sh \"{{ tag }}\"",
        ]
      }
    }]
  })
}

resource "aws_cloudwatch_log_group" "alert_actions" {
  for_each = toset([local.alert_approvals_name, local.alert_executor_name])

  name              = "/aws/lambda/${each.key}"
  retention_in_days = 30
}

resource "aws_iam_role" "alert_actions" {
  for_each = toset([local.alert_approvals_name, local.alert_executor_name])

  name = "${each.key}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 승인 함수는 서명·승인자 확인과 상태 바꾸기, 실행 함수 부르기만 한다.
resource "aws_iam_role_policy" "alert_approvals" {
  name = local.alert_approvals_name
  role = aws_iam_role.alert_actions[local.alert_approvals_name].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.alert_actions[local.alert_approvals_name].arn}:*"
      },
      {
        Sid    = "ReadParameters"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "${local.alert_parameter_arn}/cking/dev/monitoring/SLACK_SIGNING_SECRET",
          "${local.alert_parameter_arn}/cking/dev/monitoring/SLACK_BOT_TOKEN",
          aws_ssm_parameter.alert_action_approvers.arn,
        ]
      },
      {
        Sid      = "State"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.alert_analyzer.arn
      },
      {
        Sid      = "InvokeExecutor"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.alert_actions[local.alert_executor_name].arn
      },
    ]
  })
}

# 실행 함수는 목록의 조치를 그 대상에만 한다.
resource "aws_iam_role_policy" "alert_executor" {
  name = local.alert_executor_name
  role = aws_iam_role.alert_actions[local.alert_executor_name].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.alert_action_reads, [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.alert_actions[local.alert_executor_name].arn}:*"
      },
      {
        Sid    = "ReadParameters"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "${local.alert_parameter_arn}/cking/dev/monitoring/SLACK_BOT_TOKEN",
          "${local.alert_parameter_arn}/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL",
          "${local.alert_parameter_arn}/cking/dev/monitoring/SLACK_PROD_ALERT_WEBHOOK_URL",
          "${local.alert_parameter_arn}/cking/dev/monitoring/GITHUB_ACTIONS_TOKEN",
          "${local.alert_parameter_arn}/cking/prod/RELEASE_TAG",
        ]
      },
      {
        Sid      = "State"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.alert_analyzer.arn
      },
      {
        Sid    = "ServerCommands"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          data.aws_instance.app.arn,
          aws_instance.observability.arn,
          aws_ssm_document.dev_app_restart.arn,
          aws_ssm_document.dev_redis_maxmemory.arn,
          aws_ssm_document.dev_app_rollback.arn,
          aws_ssm_document.observability_query.arn,
        ]
      },
      {
        Sid      = "ReadCommandResult"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      },
      {
        Sid      = "ReadTargets"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "ReplaceBatchServer"
        Effect   = "Allow"
        Action   = "autoscaling:StartInstanceRefresh"
        Resource = ["${local.asg_arn_prefix}/dev-cking-recommendation", "${local.asg_arn_prefix}/prod-cking-recommendation"]
      },
      {
        Sid      = "ProdAppServers"
        Effect   = "Allow"
        Action   = ["autoscaling:TerminateInstanceInAutoScalingGroup", "autoscaling:SetDesiredCapacity"]
        Resource = "${local.asg_arn_prefix}/prod-cking-app"
      },
      {
        Sid      = "CommentFilter"
        Effect   = "Allow"
        Action   = "lambda:PutFunctionConcurrency"
        Resource = [aws_lambda_function.comment_filter.arn, "arn:aws:lambda:ap-northeast-2:551372961758:function:prod-cking-comment-filter"]
      },
      {
        Sid    = "ProdRedisNodeType"
        Effect = "Allow"
        Action = "elasticache:ModifyReplicationGroup"
        Resource = [
          "arn:aws:elasticache:ap-northeast-2:551372961758:replicationgroup:prod-cking-redis",
          "arn:aws:elasticache:ap-northeast-2:551372961758:cluster:prod-cking-redis-*",
        ]
      },
      {
        Sid      = "DevServerStopStart"
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:StartInstances"]
        Resource = [data.aws_instance.app.arn, aws_instance.observability.arn]
      },
    ])
  })
}

resource "aws_lambda_function" "alert_actions" {
  for_each = {
    (local.alert_approvals_name) = { handler = "approvals.handler", timeout = 10 }
    # EC2 중지·시작과 개발 되돌리기(deploy.sh)가 몇 분 걸린다
    (local.alert_executor_name) = { handler = "executor.handler", timeout = 900 }
  }

  function_name = each.key
  role          = aws_iam_role.alert_actions[each.key].arn
  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = each.value.handler
  s3_bucket     = "dev-cking-deploy-551372961758"
  s3_key        = "alert-analyzer/initial.zip"
  memory_size   = 256
  timeout       = each.value.timeout

  # 조치는 한 번에 하나만 돈다
  reserved_concurrent_executions = each.key == local.alert_executor_name ? 1 : 2

  environment {
    variables = {
      STATE_TABLE               = aws_dynamodb_table.alert_analyzer.name
      SLACK_CHANNELS            = jsonencode(local.alert_channels)
      EXECUTOR_FUNCTION         = local.alert_executor_name
      DEV_APP_INSTANCE_ID       = data.aws_instance.app.id
      OBSERVABILITY_INSTANCE_ID = aws_instance.observability.id
      QUERY_DOCUMENT            = aws_ssm_document.observability_query.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.alert_actions]

  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

# 승인한 조치를 실패했다고 다시 실행하지 않는다
resource "aws_lambda_function_event_invoke_config" "alert_executor" {
  function_name                = aws_lambda_function.alert_actions[local.alert_executor_name].function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 900
}

# Slack이 버튼 클릭을 보내는 주소. 인증은 Slack 서명(SLACK_SIGNING_SECRET)으로 한다.
resource "aws_lambda_function_url" "alert_approvals" {
  function_name      = aws_lambda_function.alert_actions[local.alert_approvals_name].function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "alert_approvals_url" {
  statement_id           = "slack-interactivity"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.alert_actions[local.alert_approvals_name].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

output "alert_approvals_url" {
  value = aws_lambda_function_url.alert_approvals.function_url
}
