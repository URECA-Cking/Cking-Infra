# 앱 서버 오토스케일링 그룹. 최소 2대(AZ마다 1대), 최대 4대, 서버당 분당 요청 6,300건을 목표로 늘리고 줄인다.
# 배포는 서버 교체다. BE CI가 배포 태그(/cking/prod/RELEASE_TAG)를 바꾸고 인스턴스 교체를 시작하면,
# 새 서버가 그 태그로 앱을 띄우고 스스로 스모크 테스트를 통과해야 ALB에 붙는다. 정상이 된 뒤 옛 서버가 빠진다.

locals {
  app_asg_name       = "prod-cking-app"
  app_launch_hook    = "prod-cking-app-launch"
  app_check_k6_image = "grafana/k6:2.2.0@sha256:9bd01d6941fca969cb61bb57d2da5ee9b385fe2aa8881df3798c196564d6ace6"
}

resource "aws_launch_template" "app" {
  name          = "prod-cking-app"
  image_id      = local.server_ami
  instance_type = "c6g.large"

  iam_instance_profile {
    name = "prod-cking-app-role"
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = base64encode(templatefile("${path.module}/templates/app-init.sh", {
    server_base          = templatefile("${path.module}/templates/server-base.sh", local.docker_versions)
    deploy_bucket        = aws_s3_bucket.this["deploy"].id
    observability_bucket = local.observability_bucket
    asg_name             = local.app_asg_name
    lifecycle_hook       = local.app_launch_hook
    k6_image             = local.app_check_k6_image
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

  monitoring {
    enabled = true
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
  name                = local.app_asg_name
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.this["app-2a"].id, aws_subnet.this["app-2b"].id]
  target_group_arns   = [aws_lb_target_group.app.arn]

  # 새 서버는 시작 대기 동안 부팅(Docker 설치, 이미지 받기, 앱 기동)과 자기 검사를 마친다.
  # 대기 상한은 그 최악값을 몰라 넉넉히 900초로 두고, 넘기면 버린다. 실제 부팅 시간은 apply 후 재서 줄인다.
  initial_lifecycle_hook {
    name                 = local.app_launch_hook
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = 900
    default_result       = "ABANDON"
  }

  # 유예는 ALB에 붙은 뒤부터 센다. 앱은 이미 검사를 통과했으니 ALB가 정상으로 보기까지(10초 × 2회)에 여유만 둔다.
  health_check_type         = "ELB"
  health_check_grace_period = 120
  default_instance_warmup   = 300

  # 첫 배포 전에는 배포 태그가 없어 새 서버가 시작 대기에서 버려진다. 서버가 정상인지는 BE 배포의 자기 검사·스모크가 확인한다.
  wait_for_capacity_timeout = "0"

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # 새 서버를 먼저 띄우고 정상이 된 뒤 옛 서버를 뺀다. BE CI의 배포도 같은 방식으로 교체를 시작한다(scripts/prod-refresh.sh).
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  tag {
    key                 = "Name"
    value               = local.app_asg_name
    propagate_at_launch = true
  }

  # 대수는 목표 추적 정책이 바꾼다.
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "app_requests" {
  name                   = "prod-cking-app-requests"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = 6300
  }
}
