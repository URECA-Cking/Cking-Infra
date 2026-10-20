# 앱 서버 오토스케일링 그룹. 최소 2대(AZ마다 1대), 최대 4대, 평균 CPU 50%를 목표로 늘리고 줄인다.
# 배포는 서버 교체다. BE CI가 배포 태그(/cking/prod/RELEASE_TAG)를 바꾸고 인스턴스 교체를 시작하면,
# 새 서버가 그 태그로 앱을 띄우고 ALB 헬스체크를 통과한 뒤 옛 서버가 빠진다.

resource "aws_launch_template" "app" {
  name          = "prod-cking-app"
  image_id      = local.server_ami
  instance_type = "t4g.small"

  iam_instance_profile {
    name = "prod-cking-app-role"
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = base64encode(templatefile("${path.module}/templates/app-init.sh", {
    server_base          = templatefile("${path.module}/templates/server-base.sh", local.docker_versions)
    deploy_bucket        = aws_s3_bucket.this["deploy"].id
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
      volume_size = 30
      encrypted   = true
    }
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "prod-cking-app" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "prod-cking-app-root" }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "prod-cking-app"
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.this["app-2a"].id, aws_subnet.this["app-2b"].id]
  target_group_arns   = [aws_lb_target_group.app.arn]

  # 첫 부팅(Docker 설치, 이미지 받기, 앱 기동)이 끝나기 전에 헬스체크로 교체되지 않게 여유를 둔다.
  health_check_type         = "ELB"
  health_check_grace_period = 600
  default_instance_warmup   = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # 새 서버를 먼저 띄우고 정상이 된 뒤 옛 서버를 뺀다. BE CI의 배포도 같은 방식으로 교체를 시작한다.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  tag {
    key                 = "Name"
    value               = "prod-cking-app"
    propagate_at_launch = true
  }

  # 대수는 목표 추적 정책이 바꾼다.
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "app_cpu" {
  name                   = "prod-cking-app-cpu50"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}
