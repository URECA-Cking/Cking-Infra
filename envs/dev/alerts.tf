resource "aws_sns_topic" "alerts" {
  name = "dev-cking-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = data.aws_ssm_parameter.alert_email.value
}

locals {
  status_check_instances = {
    observability = aws_instance.observability.id
    app           = data.aws_instance.app.id
  }
}

resource "aws_cloudwatch_metric_alarm" "system_check" {
  for_each = local.status_check_instances

  alarm_name          = "dev-cking-${each.key}-system-check"
  alarm_description   = "AWS 하드웨어 문제. 복구는 EC2 기본 자동 복구가 한다"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "instance_check" {
  for_each = local.status_check_instances

  alarm_name          = "dev-cking-${each.key}-instance-check"
  alarm_description   = "OS 응답 없음. 재부팅한다"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn, "arn:aws:automate:ap-northeast-2:ec2:reboot"]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
