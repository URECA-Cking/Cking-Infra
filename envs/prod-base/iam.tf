# 운영 EC2가 쓰는 역할. 서버와 같은 apply로 만들면 전파 전에 부팅해 SSM 에이전트가 자격 증명을 받지 못해 따로 먼저 만든다.
# 버킷·함수·앱 서버 그룹은 envs/prod에서 만들므로 이름으로 가리킨다.
locals {
  parameter_arn        = "arn:aws:ssm:ap-northeast-2:551372961758:parameter"
  deploy_bucket        = "prod-cking-deploy-551372961758-ap-northeast-2-an"
  uploads_bucket       = "prod-cking-uploads-551372961758-ap-northeast-2-an"
  observability_bucket = "dev-cking-observability-551372961758-ap-northeast-2-an"
  comment_filter_arn   = "arn:aws:lambda:ap-northeast-2:551372961758:function:prod-cking-comment-filter"
  # 이미지 파이프라인 결과 큐(envs/prod/image_pipeline.tf). 사전 서명 PUT은 서명한 이 역할의 권한으로 동작해 raw/ 쓰기가 필요하다
  image_results_queue_arn = "arn:aws:sqs:ap-northeast-2:551372961758:prod-cking-image-results"
  ec2_arn                 = "arn:aws:ec2:ap-northeast-2:551372961758"
  upload_prefixes = [
    "subscription-verifications",
    "post-images",
    "member-profile-images",
    "creator-space-profile-images",
  ]

  ec2_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  app_agent_statements = [
    {
      Sid       = "ListAppAgentConfig"
      Effect    = "Allow"
      Action    = "s3:ListBucket"
      Resource  = "arn:aws:s3:::${local.observability_bucket}"
      Condition = { StringLike = { "s3:prefix" = ["app-agent/", "app-agent/*"] } }
    },
    {
      Sid      = "ReadAppAgentConfig"
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = "arn:aws:s3:::${local.observability_bucket}/app-agent/*"
    },
  ]
}

resource "aws_iam_role" "app" {
  name               = "prod-cking-app-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "prod-cking-app"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadProdParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "${local.parameter_arn}/cking/prod/*"
      },
      {
        Sid      = "ReadDeployFiles"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${local.deploy_bucket}/releases/*"
      },
      {
        Sid      = "UploadObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = [for p in local.upload_prefixes : "arn:aws:s3:::${local.uploads_bucket}/${p}/*"]
      },
      {
        Sid      = "PresignRawUploads"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${local.uploads_bucket}/raw/*"
      },
      {
        Sid      = "ReadImageResults"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        Resource = local.image_results_queue_arn
      },
      {
        Sid      = "NotFoundAs404"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${local.uploads_bucket}"
      },
      {
        Sid      = "InvokeCommentFilter"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunctionUrl", "lambda:InvokeFunction"]
        Resource = local.comment_filter_arn
      },
      {
        Sid      = "CompleteOwnLaunch"
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName/prod-cking-app"
      },
    ], local.app_agent_statements)
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "prod-cking-app-role"
  role = aws_iam_role.app.name
}

resource "aws_iam_role" "recommendation" {
  name               = "prod-cking-recommendation-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "recommendation_ssm" {
  role       = aws_iam_role.recommendation.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "recommendation" {
  name = "prod-cking-recommendation"
  role = aws_iam_role.recommendation.id

  # 앱 비밀값(/cking/prod/)과 겹치지 않는 경로만 읽는다.
  # 상태 디스크는 서버가 바뀌어도 남도록 따로 두고, 새 서버가 부팅하며 자기에게 붙인다.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadRecommendationParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "${local.parameter_arn}/cking/prod-recommendation/*"
      },
      {
        Sid      = "ReadRecommendationReleases"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${local.deploy_bucket}/recommendation/releases/*"
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
        Resource  = "${local.ec2_arn}:volume/*"
        Condition = { StringEquals = { "aws:ResourceTag/Name" = "prod-cking-recommendation-state" } }
      },
      {
        Sid       = "AttachToRecommendationServer"
        Effect    = "Allow"
        Action    = "ec2:AttachVolume"
        Resource  = "${local.ec2_arn}:instance/*"
        Condition = { StringEquals = { "aws:ResourceTag/Name" = "prod-cking-recommendation" } }
      },
      {
        Sid      = "CompleteOwnLaunch"
        Effect   = "Allow"
        Action   = "autoscaling:CompleteLifecycleAction"
        Resource = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName/prod-cking-recommendation"
      },
    ], local.app_agent_statements)
  })
}

resource "aws_iam_instance_profile" "recommendation" {
  name = "prod-cking-recommendation-role"
  role = aws_iam_role.recommendation.name
}

resource "aws_iam_role" "monitor" {
  name               = "prod-cking-monitor-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "monitor_ssm" {
  role       = aws_iam_role.monitor.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "monitor" {
  name = "prod-cking-monitor"
  role = aws_iam_role.monitor.id

  # Redis 감시 전용 사용자의 비밀번호만 읽는다. 앱 비밀값(/cking/prod/)은 읽지 않는다.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadMonitorParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "${local.parameter_arn}/cking/prod-monitor/*"
      },
    ], local.app_agent_statements)
  })
}

resource "aws_iam_instance_profile" "monitor" {
  name = "prod-cking-monitor-role"
  role = aws_iam_role.monitor.name
}

# NAT 인스턴스. 사람이 들어가 볼 때만 SSM을 쓴다. 다른 권한은 없다.
resource "aws_iam_role" "nat" {
  name               = "prod-cking-nat-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "prod-cking-nat-role"
  role = aws_iam_role.nat.name
}

resource "aws_iam_role" "k6" {
  name               = "prod-cking-k6-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "k6_ssm" {
  role       = aws_iam_role.k6.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 운영 부하 테스트 k6가 Access Token을 직접 서명하도록 JWT 비밀값을 읽는다. DB·Redis 비밀번호는 앱 서버 역할만 읽는다.
# 실행기(loadtest/runner/ltrun.py)는 운영 앱 서버에 데이터 작업(되돌리기·시딩·검증)을 보낸다. 앱 서버에서 root 명령이 되므로,
# k6 서버는 운영 부하 테스트 동안만 만든다(k6_enabled). 지표 조회는 조회 문서만 허용한 loadtest-cking-query로 넘어가서 한다.
resource "aws_iam_role_policy" "k6" {
  name = "prod-cking-k6-loadtest-runner"
  role = aws_iam_role.k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSecrets"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "${local.parameter_arn}/cking/prod/JWT_SECRET",
          "${local.parameter_arn}/cking/dev/monitoring/SLACK_PROD_ALERT_WEBHOOK_URL",
        ]
      },
      {
        Sid       = "RunOnProdApp"
        Effect    = "Allow"
        Action    = "ssm:SendCommand"
        Resource  = "arn:aws:ec2:ap-northeast-2:551372961758:instance/*"
        Condition = { StringEquals = { "ssm:resourceTag/aws:autoscaling:groupName" = "prod-cking-app" } }
      },
      {
        Sid      = "RunShellDocument"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:ap-northeast-2::document/AWS-RunShellScript"
      },
      {
        Sid    = "Describe"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ec2:DescribeInstances",
          "autoscaling:DescribeAutoScalingGroups",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
        ]
        Resource = "*"
      },
      {
        Sid      = "PauseAppGroup"
        Effect   = "Allow"
        Action   = ["autoscaling:SuspendProcesses", "autoscaling:ResumeProcesses"]
        Resource = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName/prod-cking-app"
      },
      {
        Sid      = "AssumeQueryRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::551372961758:role/loadtest-cking-query"
      },
      {
        Sid      = "WriteResults"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "arn:aws:s3:::loadtest-cking-results-551372961758-ap-northeast-2-an/prod/*"
      },
      {
        Sid       = "ListResults"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = "arn:aws:s3:::loadtest-cking-results-551372961758-ap-northeast-2-an"
        Condition = { StringLike = { "s3:prefix" = ["prod/*"] } }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "k6" {
  name = "prod-cking-k6-role"
  role = aws_iam_role.k6.name
}

# RDS Enhanced Monitoring이 OS 지표를 CloudWatch Logs(RDSOSMetrics)로 보내는 역할. RDS와 같은 apply로 만들면
# IAM 전파 전에 RDS가 역할을 검사해 실패할 수 있어 여기서 먼저 만든다.
resource "aws_iam_role" "rds_monitoring" {
  name = "prod-cking-rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
