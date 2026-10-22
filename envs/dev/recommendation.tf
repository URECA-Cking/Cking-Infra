# 개발 추천 배치(콘텐츠 작업자). 운영 설계(#102)와 같이 배치 저장소 CI가 배포 패키지를 올리고 배포 버전 값을 바꾼 뒤
# 서버를 교체하면, 새 서버가 부팅하며 그 버전의 패키지를 받는다.

locals {
  recommendation_name          = "dev-cking-recommendation"
  recommendation_release_param = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev-recommendation/RELEASE"
  # 교체·시작 대기 권한은 그룹 이름으로 한정한다. 그룹 ARN을 참조하면 plan 때 값을 몰라 정책 전체가 미정으로 보인다.
  recommendation_asg_arn = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName/${local.recommendation_name}"
  recommendation_state   = "dev-cking-recommendation-state"
  recommendation_hook    = "dev-cking-recommendation-launch"

  # 개발 앱 서버·운영 서버와 같은 AMI(ubuntu-resolute-26.04-arm64-server-20260604)와 Docker 버전(envs/prod/servers.tf).
  recommendation_ami = "ami-019e063f3fff5d27f"
  recommendation_docker_versions = {
    docker_version     = "5:29.8.1-1~ubuntu.26.04~resolute"
    containerd_version = "2.3.5-1~ubuntu.26.04~resolute"
    compose_version    = "5.5.1-1~ubuntu.26.04~resolute"
  }
}

# 배치 저장소 CI: develop에서 배포 패키지 업로드 → 배포 버전 값 갱신 → 서버 교체 시작.
resource "aws_iam_role" "recommendation_deploy" {
  name = "dev-cking-recommendation-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-LLM-Benchmark@1391984166:ref:refs/heads/develop"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "recommendation_deploy" {
  name = "dev-cking-recommendation-deploy"
  role = aws_iam_role.recommendation_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 같은 커밋을 다시 실행할 때 올려 둔 패키지가 있는지 본다. 목록 권한이 없으면 없는 파일도 403이라 구분하지 못한다.
      {
        Sid       = "ListReleases"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.deploy_bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["recommendation/releases/", "recommendation/releases/*"] } }
      },
      {
        Sid      = "ReleasePackages"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.deploy_bucket_arn}/recommendation/releases/*"
      },
      # 읽기는 지금 배포된 버전이 이번 커밋보다 새로운지 비교할 때 쓴다.
      {
        Sid      = "SetRelease"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = local.recommendation_release_param
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

# 개발 추천 배치 서버. 운영 설계(#102)와 같이 1대짜리 서버 그룹에 상태 디스크를 따로 두고, 새 서버가 부팅하며 붙인다.
# 구매 방식만 스팟이다(서울 t4g.small 중단 빈도 5% 미만). 중단되면 그룹이 새 서버를 띄우고 상태 디스크를 다시 붙인다.

resource "aws_ssm_parameter" "recommendation_be_url" {
  name  = "/cking/dev-recommendation/CKING_BE_URL"
  type  = "String"
  value = "https://dev-api.cking.co.kr"
}

# 태그 분류 호출의 하루 상한. 배치 저장소 예시 값이며, 공급자 지출 한도를 정하면 맞춘다.
resource "aws_ssm_parameter" "recommendation_tag_daily_calls" {
  name  = "/cking/dev-recommendation/CKING_TAG_DAILY_CALLS"
  type  = "String"
  value = "100"
}

# 캐시·적재 기록·예산 파일. 잃으면 배치 문서의 복구 절차를 따라야 하므로 지우지 않는다.
# 쓰임새를 아직 재지 않아 넉넉히 두고, 디스크 여유 경보(20% 미만)가 이 디스크도 본다.
resource "aws_ebs_volume" "recommendation_state" {
  availability_zone = data.aws_subnet.public_2a.availability_zone
  type              = "gp3"
  size              = 10
  encrypted         = true

  tags = { Name = local.recommendation_state }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_security_group" "recommendation" {
  name        = "dev-cking-recommendation-sg"
  description = "Dev recommendation batch server. No inbound, SSM only"
  vpc_id      = data.aws_vpc.main.id

  tags = { Name = "dev-cking-recommendation-sg" }
}

resource "aws_vpc_security_group_egress_rule" "recommendation_all" {
  security_group_id = aws_security_group.recommendation.id
  description       = "Packages, AWS APIs, BE, OpenAI, DeepInfra, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "recommendation" {
  name = "dev-cking-recommendation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "recommendation_ssm" {
  role       = aws_iam_role.recommendation.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 앱 비밀값(/cking/dev/)과 겹치지 않는 경로만 읽는다. 상태 디스크는 이 이름표의 디스크를 이 이름표의 서버에만 붙인다.
resource "aws_iam_role_policy" "recommendation" {
  name = "dev-cking-recommendation"
  role = aws_iam_role.recommendation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRecommendationParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev-recommendation/*"
      },
      {
        Sid      = "ReadReleases"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.deploy_bucket_arn}/recommendation/releases/*"
      },
      {
        Sid      = "FindStateVolume"
        Effect   = "Allow"
        Action   = "ec2:DescribeVolumes"
        Resource = "*"
      },
      {
        Sid       = "AttachStateVolume"
        Effect    = "Allow"
        Action    = "ec2:AttachVolume"
        Resource  = "arn:aws:ec2:ap-northeast-2:551372961758:volume/*"
        Condition = { StringEquals = { "aws:ResourceTag/Name" = local.recommendation_state } }
      },
      {
        Sid       = "AttachToRecommendationServer"
        Effect    = "Allow"
        Action    = "ec2:AttachVolume"
        Resource  = "arn:aws:ec2:ap-northeast-2:551372961758:instance/*"
        Condition = { StringEquals = { "aws:ResourceTag/Name" = local.recommendation_name } }
      },
      {
        Sid      = "CompleteOwnLaunch"
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = local.recommendation_asg_arn
      },
      {
        Sid       = "ListAppAgentConfig"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.observability.arn
        Condition = { StringLike = { "s3:prefix" = ["app-agent/", "app-agent/*"] } }
      },
      {
        Sid      = "ReadAppAgentConfig"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.observability.arn}/app-agent/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "recommendation" {
  name = "dev-cking-recommendation-role"
  role = aws_iam_role.recommendation.name
}

# 운영 서버와 같은 공통 준비(envs/prod/templates/server-base.sh)와 부팅 스크립트를 써서 개발에서 같은 부팅 과정을 확인한다.
resource "aws_launch_template" "recommendation" {
  name          = local.recommendation_name
  image_id      = local.recommendation_ami
  instance_type = "t4g.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.recommendation.name
  }

  # 개발 퍼블릭 서브넷은 공인 IP를 자동으로 붙이지 않는다. NAT가 없어 외부 API를 부르려면 공인 IP가 필요하다.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.recommendation.id]
  }

  user_data = base64encode(templatefile("${path.module}/../prod/templates/recommendation-init.sh", {
    server_base          = templatefile("${path.module}/../prod/templates/server-base.sh", local.recommendation_docker_versions)
    asg_name             = local.recommendation_name
    lifecycle_hook       = local.recommendation_hook
    state_volume         = local.recommendation_state
    param_path           = "/cking/dev-recommendation/"
    deploy_bucket        = "dev-cking-deploy-551372961758"
    observability_bucket = aws_s3_bucket.observability.bucket
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

resource "aws_autoscaling_group" "recommendation" {
  name                = local.recommendation_name
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [data.aws_subnet.public_2a.id]
  health_check_type   = "EC2"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.recommendation.id
        version            = aws_launch_template.recommendation.latest_version
      }
    }
  }

  # 새 서버는 상태 디스크를 붙이고 배포 버전의 패키지를 설치한 뒤에야 들어온다. 실패하거나 900초가 지나면 버려진다.
  initial_lifecycle_hook {
    name                 = local.recommendation_hook
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = 900
    default_result       = "ABANDON"
  }

  # 스팟 자리가 없으면 서버가 뜨지 않을 수 있어 apply는 기다리지 않는다. 서버 상태는 런북으로 확인한다.
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
