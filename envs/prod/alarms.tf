# AWS 관리형 서비스(ALB, 서버 그룹, ElastiCache, RDS) 경보. 앱 경보는 Grafana가 맡고, 이 경보는 관측 서버·피어링이 죽어도 울리도록
# CloudWatch에 둔다. 받는 곳은 Grafana 운영 경보와 같은 운영 채널(Amazon Q)이고, 그 경로가 끊겨도 알 수 있게 메일로도 받는다.

locals {
  alarm_runbook  = "https://github.com/URECA-Cking/Cking-Infra/blob/main/docs/runbooks"
  slack_team_id  = "T0CAUMA01A4"
  slack_channel  = "C0CAXUX1FKN"
  redis_node_ids = [for i in range(1, aws_elasticache_replication_group.main.num_cache_clusters + 1) : format("%s-%03d", aws_elasticache_replication_group.main.replication_group_id, i)]
}

data "aws_ssm_parameter" "alert_email" {
  name = "/cking/dev/monitoring/ALERT_EMAIL"
}

resource "aws_sns_topic" "alerts" {
  name = "prod-cking-alerts"
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountOwner"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::551372961758:root" }
        Action = [
          "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission", "SNS:RemovePermission",
          "SNS:DeleteTopic", "SNS:Subscribe", "SNS:ListSubscriptionsByTopic", "SNS:Publish",
        ]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid       = "CloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { ArnLike = { "aws:SourceArn" = "arn:aws:cloudwatch:ap-northeast-2:551372961758:alarm:prod-cking-*" } }
      },
      {
        Sid       = "LaunchFailureEvents"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.launch_failed.arn } }
      },
      # 계정 보안 기준선(envs/security)의 GuardDuty 높음 경보.
      {
        Sid       = "SecurityEvents"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = { ArnLike = { "aws:SourceArn" = "arn:aws:events:ap-northeast-2:551372961758:rule/cking-security-*" } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = data.aws_ssm_parameter.alert_email.value
}

# 채널 구성원이 Slack에서 실행할 수 있는 범위(guardrail)는 비워 두면 관리자 권한이 된다. 알림에 필요한 CloudWatch 읽기만 준다.
resource "aws_iam_policy" "chatbot_notifications" {
  name = "prod-cking-chatbot-notifications"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "chatbot" {
  name = "prod-cking-chatbot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "chatbot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "chatbot" {
  role       = aws_iam_role.chatbot.name
  policy_arn = aws_iam_policy.chatbot_notifications.arn
}

# Amazon Q 설정은 서울 리전 API가 없어 지원 리전에서 만든다. 구독하는 SNS 주제는 서울에 있어도 된다.
resource "aws_chatbot_slack_channel_configuration" "alerts" {
  region                = "us-west-2"
  configuration_name    = "prod-cking-alerts"
  iam_role_arn          = aws_iam_role.chatbot.arn
  slack_team_id         = local.slack_team_id
  slack_channel_id      = local.slack_channel
  sns_topic_arns        = [aws_sns_topic.alerts.arn]
  guardrail_policy_arns = [aws_iam_policy.chatbot_notifications.arn]
  logging_level         = "ERROR"
}

# ALB가 요청을 보낼 정상 서버가 없다. 서비스 중단이다.
resource "aws_cloudwatch_metric_alarm" "alb_no_healthy" {
  alarm_name          = "prod-cking-alb-no-healthy-target"
  alarm_description   = "정상 앱 서버 0대. 런북: ${local.alarm_runbook}/prod-alb.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# 서버 하나를 교체하는 상한이 시작 대기 900초다. 15분 넘게 최소 대수(2)보다 적으면 교체가 실패하고 있다.
resource "aws_cloudwatch_metric_alarm" "alb_few_healthy" {
  alarm_name          = "prod-cking-alb-few-healthy-targets"
  alarm_description   = "정상 앱 서버가 15분째 2대 미만. 런북: ${local.alarm_runbook}/prod-alb.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 15
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# 앱까지 가지 못한 요청(ALB가 만든 502·503·504)은 앱 지표에 없다. 기준은 Grafana 서버 오류 증가와 같다(5분에 30건 이상일 때 5%).
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "prod-cking-alb-5xx"
  alarm_description   = "ALB가 만든 5xx가 5분 동안 요청의 5% 초과. 런북: ${local.alarm_runbook}/prod-alb.md"
  evaluation_periods  = 1
  threshold           = 0.05
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "ratio"
    expression  = "IF(FILL(requests, 0) >= 30, FILL(elb5xx, 0) / requests, 0)"
    return_data = true
  }

  metric_query {
    id = "elb5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      stat        = "Sum"
      period      = 300
    }
  }
}

# 늘리려던 서버가 부팅·자기 검사에서 버려져도 정상 서버 수는 그대로라 위 경보로는 잡히지 않는다.
resource "aws_cloudwatch_event_rule" "launch_failed" {
  name        = "prod-cking-launch-failed"
  description = "운영 서버 그룹의 서버 띄우기 실패"

  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance Launch Unsuccessful"]
    detail        = { AutoScalingGroupName = [aws_autoscaling_group.app.name, aws_autoscaling_group.monitor.name] }
  })
}

# Amazon Q는 정해진 형식(custom notification)만 채널에 보여 준다.
resource "aws_cloudwatch_event_target" "launch_failed" {
  rule = aws_cloudwatch_event_rule.launch_failed.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      group   = "$.detail.AutoScalingGroupName"
      status  = "$.detail.StatusMessage"
      started = "$.detail.StartTime"
    }
    input_template = <<-EOT
      {
        "version": "1.0",
        "source": "custom",
        "content": {
          "textType": "client-markdown",
          "title": ":warning: 운영 서버 띄우기 실패: <group>",
          "description": "<started> <status>",
          "nextSteps": ["런북: ${local.alarm_runbook}/prod-launch-failed.md"]
        }
      }
    EOT
  }
}

# noeviction이라 메모리가 차면 응모 쓰기가 거부된다. 응모 키는 만료 시간이 있어 메모리가 초당 건수 × 1.7~2.1MB에서 멈추므로
# (부하 테스트 2차 계산값) small에서 70%는 초당 약 370~450건이 이어져야 닿는다. 정상 부하로는 닿지 않는 값이라 닿으면 이상 신호다.
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  for_each = toset(local.redis_node_ids)

  alarm_name          = "prod-cking-redis-memory-${each.key}"
  alarm_description   = "ElastiCache 메모리 사용률 10분째 70% 초과. 런북: ${local.alarm_runbook}/prod-elasticache.md"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Redis는 명령을 한 스레드에서 처리하므로 엔진 CPU가 곧 처리 한계다.
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  for_each = toset(local.redis_node_ids)

  alarm_name          = "prod-cking-redis-engine-cpu-${each.key}"
  alarm_description   = "ElastiCache 엔진 CPU 10분째 80% 초과. 런북: ${local.alarm_runbook}/prod-elasticache.md"
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 10
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# 부하 테스트 최대(db.t4g.micro, 초당 150 반영 시도에서 37.5%)의 2배를 넘는 상태가 15분 이어질 때.
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "prod-cking-rds-cpu"
  alarm_description   = "RDS CPU 15분째 80% 초과. 런북: ${local.alarm_runbook}/prod-rds.md"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 15
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# 저장 공간은 자동으로 늘어난다(최대 100GiB). 2GiB 아래로 15분 남아 있으면 늘어나지 못했거나 상한에 닿았다.
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "prod-cking-rds-free-storage"
  alarm_description   = "RDS 남은 저장 공간 15분째 2GiB 미만. 런북: ${local.alarm_runbook}/prod-rds.md"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 15
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
