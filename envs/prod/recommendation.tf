# 운영 추천 배치(콘텐츠 작업자). 개발 추천 배치 서버(envs/dev/recommendation.tf)와 같은 구조다. 1대짜리 서버 그룹에 상태 디스크를
# 따로 두고 새 서버가 부팅하며 붙인다. 배치 저장소 main CI가 개발에서 확인한 패키지를 운영 배포 버킷에 올리고 배포 버전 값을 바꾼 뒤
# 서버를 교체한다. 역할과 인스턴스 프로필은 envs/prod-base에 있다.

locals {
  recommendation_name  = "prod-cking-recommendation"
  recommendation_state = "prod-cking-recommendation-state"
  recommendation_hook  = "prod-cking-recommendation-launch"
  # 교체 권한은 그룹 이름으로 한정한다. 그룹 ARN을 참조하면 plan 때 값을 몰라 정책 전체가 미정으로 보인다.
  recommendation_asg_arn = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName/${local.recommendation_name}"
}

# 배치 저장소 CI: main에서 개발 CI가 확인하고 올린 패키지를 운영 배포 버킷에 복사 → 배포 버전 값 갱신 → 서버 교체 시작.
resource "aws_iam_role" "recommendation_deploy" {
  name = "prod-cking-recommendation-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-LLM-Benchmark@1391984166:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "recommendation_deploy" {
  name = "prod-cking-recommendation-deploy"
  role = aws_iam_role.recommendation_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListDevReleases"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = "arn:aws:s3:::dev-cking-deploy-551372961758"
        Condition = { StringLike = { "s3:prefix" = ["recommendation/releases/", "recommendation/releases/*"] } }
      },
      {
        Sid      = "ReadDevReleases"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::dev-cking-deploy-551372961758/recommendation/releases/*"
      },
      # 같은 커밋을 다시 실행할 때 올려 둔 패키지가 있는지 본다. 목록 권한이 없으면 없는 파일도 403이라 구분하지 못한다.
      {
        Sid       = "ListProdReleases"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.this["deploy"].arn
        Condition = { StringLike = { "s3:prefix" = ["recommendation/releases/", "recommendation/releases/*"] } }
      },
      {
        Sid      = "ProdReleasePackages"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.this["deploy"].arn}/recommendation/releases/*"
      },
      # 읽기는 지금 배포된 버전이 이번 커밋보다 새로운지 비교할 때 쓴다.
      {
        Sid      = "SetRelease"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/prod-recommendation/RELEASE"
      },
      {
        Sid      = "RefreshServer"
        Effect   = "Allow"
        Action   = "autoscaling:StartInstanceRefresh"
        Resource = local.recommendation_asg_arn
      },
      {
        Sid      = "WatchRefresh"
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeInstanceRefreshes"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_ssm_parameter" "recommendation_be_url" {
  name  = "/cking/prod-recommendation/CKING_BE_URL"
  type  = "String"
  value = "https://api.cking.co.kr"
}

# 태그 분류 호출의 하루 상한. 개발과 같은 100이다(호출당 최악 $0.0018, 한 달 최대 약 $5.4).
# OpenAI 키를 개발과 같이 써서 지출 한도(월 $15)도 개발과 나눠 쓴다.
resource "aws_ssm_parameter" "recommendation_tag_daily_calls" {
  name  = "/cking/prod-recommendation/CKING_TAG_DAILY_CALLS"
  type  = "String"
  value = "100"
}

# 캐시·적재 기록·예산 파일. 잃으면 배치 문서의 복구 절차를 따라야 하므로 지우지 않는다. 운영을 내릴 때는 이 설정을 먼저 뺀다.
resource "aws_ebs_volume" "recommendation_state" {
  availability_zone = aws_subnet.this["app-2a"].availability_zone
  type              = "gp3"
  size              = 10
  encrypted         = true

  tags = { Name = local.recommendation_state }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_launch_template" "recommendation" {
  name          = local.recommendation_name
  image_id      = local.server_ami
  instance_type = "t4g.small"

  iam_instance_profile {
    name = "prod-cking-recommendation-role"
  }

  vpc_security_group_ids = [aws_security_group.recommendation.id]

  user_data = base64encode(templatefile("${path.module}/templates/recommendation-init.sh", {
    server_base          = templatefile("${path.module}/templates/server-base.sh", local.docker_versions)
    asg_name             = local.recommendation_name
    lifecycle_hook       = local.recommendation_hook
    state_volume         = local.recommendation_state
    param_path           = "/cking/prod-recommendation/"
    deploy_bucket        = aws_s3_bucket.this["deploy"].bucket
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
    tags          = { Name = local.recommendation_name }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.recommendation_name}-root" }
  }
}

# 운영은 온디맨드다. 스팟은 중단돼도 몇 분 늦어질 뿐이지만 자리가 없으면 그동안 배치가 멈추고, 운영을 띄워 두는 기간(약 2주)에는 차액이 약 $5다.
# 상태 디스크가 2a에 있어 서버도 2a에만 띄운다.
resource "aws_autoscaling_group" "recommendation" {
  name                = local.recommendation_name
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.this["app-2a"].id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.recommendation.id
    version = aws_launch_template.recommendation.latest_version
  }

  # 새 서버는 상태 디스크를 붙이고 배포 버전의 패키지를 설치한 뒤에야 들어온다. 실패하거나 900초가 지나면 버려진다.
  initial_lifecycle_hook {
    name                 = local.recommendation_hook
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = 900
    default_result       = "ABANDON"
  }

  # 배치 저장소의 첫 운영 배포 전에는 배포 버전 값이 없어 서버가 시작 대기에서 버려지므로 apply는 기다리지 않는다.
  wait_for_capacity_timeout = "0"

  # 상태 디스크를 한 서버에만 붙일 수 있어 기존 서버를 먼저 내린다. 배치 저장소 CI의 교체도 같은 설정이다.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Name"
    value               = local.recommendation_name
    propagate_at_launch = true
  }
}
