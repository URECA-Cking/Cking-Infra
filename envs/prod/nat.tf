# NAT 방식. gateway는 AZ마다 관리형 NAT Gateway, instance는 AZ마다 t4g.nano NAT 인스턴스다.
# 운영 NAT를 지나는 데이터가 하루 1GB 안팎이라 비용 대부분이 켜 둔 시간 요금이다(게이트웨이 월 약 $86, 인스턴스 약 $9).
# 인스턴스는 패치·복구를 직접 맡는 대신 하드웨어 고장은 시스템 검사 경보가 같은 인스턴스로 복구하고(EIP·주소 유지), OS가 멈추면 재부팅한다.

variable "nat_mode" {
  type    = string
  default = "instance"

  validation {
    condition     = contains(["gateway", "instance"], var.nat_mode)
    error_message = "nat_mode는 gateway 또는 instance다."
  }
}

locals {
  nat_zones      = var.nat_mode == "instance" ? toset(local.zones) : toset([])
  nat_public_ips = var.nat_mode == "gateway" ? [for e in aws_eip.nat : e.public_ip] : [for e in aws_eip.nat_instance : e.public_ip]
}

resource "aws_security_group" "nat" {
  name        = "prod-cking-nat-sg"
  description = "NAT instance: app subnets out to the internet"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_app" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = local.app_subnets_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_out" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "nat" {
  for_each = local.nat_zones

  ami                    = local.server_ami
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.this["public-${each.key}"].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  iam_instance_profile   = "prod-cking-nat-role"
  source_dest_check      = false

  user_data = templatefile("${path.module}/templates/nat-init.sh", {
    vpc_cidr = aws_vpc.main.cidr_block
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "prod-cking-nat-${each.key}" }
}

resource "aws_eip" "nat_instance" {
  for_each = local.nat_zones

  domain   = "vpc"
  instance = aws_instance.nat[each.key].id
  tags     = { Name = "prod-cking-nat-instance-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_cloudwatch_metric_alarm" "nat_system_check" {
  for_each = local.nat_zones

  alarm_name          = "prod-cking-nat-${each.key}-system-check"
  alarm_description   = "NAT 인스턴스 시스템 검사 실패(하드웨어). 같은 인스턴스로 복구한다. 런북: ${local.alarm_runbook}/prod-nat.md"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.nat[each.key].id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:aws:automate:ap-northeast-2:ec2:recover", aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "nat_instance_check" {
  for_each = local.nat_zones

  alarm_name          = "prod-cking-nat-${each.key}-instance-check"
  alarm_description   = "NAT 인스턴스 인스턴스 검사 실패(OS). 재부팅한다. 런북: ${local.alarm_runbook}/prod-nat.md"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.nat[each.key].id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:aws:swf:ap-northeast-2:551372961758:action/actions/AWS_EC2.InstanceId.Reboot/1.0", aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
