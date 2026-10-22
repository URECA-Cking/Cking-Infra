# 운영 EC2가 쓰는 역할. 서버와 같은 apply로 만들면 전파 전에 부팅해 SSM 에이전트가 자격 증명을 받지 못해 따로 먼저 만든다.
# 버킷·함수·앱 서버 그룹은 envs/prod에서 만들므로 이름으로 가리킨다.
locals {
  parameter_arn        = "arn:aws:ssm:ap-northeast-2:551372961758:parameter"
  deploy_bucket        = "prod-cking-deploy-551372961758-ap-northeast-2-an"
  uploads_bucket       = "prod-cking-uploads-551372961758-ap-northeast-2-an"
  observability_bucket = "dev-cking-observability-551372961758-ap-northeast-2-an"
  comment_filter_arn   = "arn:aws:lambda:ap-northeast-2:551372961758:function:prod-cking-comment-filter"
  ec2_arn              = "arn:aws:ec2:ap-northeast-2:551372961758"
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

resource "aws_iam_role" "k6" {
  name               = "prod-cking-k6-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "k6_ssm" {
  role       = aws_iam_role.k6.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 운영 부하 테스트 k6가 Access Token을 직접 서명하도록 JWT 비밀값 하나만 읽는다. 다른 운영 비밀값은 읽지 않는다.
resource "aws_iam_role_policy" "k6" {
  name = "prod-cking-k6-read-jwt-secret"
  role = aws_iam_role.k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadJwtSecret"
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = "${local.parameter_arn}/cking/prod/JWT_SECRET"
    }]
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
