# 감시용 서버. ElastiCache 지표를 관측 서버로 보내고, 사람이 Mac에서 RDS에 들어갈 때 SSM 포트 포워딩 경유지로 쓴다.
# 저장해 둘 상태가 없어 1대짜리 오토스케일링 그룹으로 두고, 고장 나면 2a·2b 중 아무 데나 새로 뜬다.

resource "aws_launch_template" "monitor" {
  name          = "prod-cking-monitor"
  image_id      = local.server_ami
  instance_type = "t4g.micro"

  iam_instance_profile {
    name = "prod-cking-monitor-role"
  }

  vpc_security_group_ids = [aws_security_group.monitor.id]

  user_data = base64encode(templatefile("${path.module}/templates/monitor-init.sh", {
    server_base          = templatefile("${path.module}/templates/server-base.sh", local.docker_versions)
    observability_bucket = local.observability_bucket
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_type = "gp3"
      volume_size = 20
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "prod-cking-monitor" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "prod-cking-monitor-root" }
  }
}

resource "aws_autoscaling_group" "monitor" {
  name                = "prod-cking-monitor"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.this["app-2a"].id, aws_subnet.this["app-2b"].id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.monitor.id
    version = aws_launch_template.monitor.latest_version
  }

  # 시작 템플릿이 바뀌면 새 서버로 바꾼다. 1대라 잠깐 수집이 끊기는 것을 감수한다.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = "prod-cking-monitor"
    propagate_at_launch = true
  }
}
