# 운영 EC2가 쓰는 역할. 서버와 같은 apply로 만들면 전파 전에 부팅해 SSM 에이전트가 자격 증명을 받지 못해 따로 먼저 만든다.
# 버킷은 envs/prod에서 만들므로 이름으로 가리킨다.
locals {
  parameter_arn        = "arn:aws:ssm:ap-northeast-2:551372961758:parameter"
  deploy_bucket        = "prod-cking-deploy-551372961758-ap-northeast-2-an"
  uploads_bucket       = "prod-cking-uploads-551372961758-ap-northeast-2-an"
  observability_bucket = "dev-cking-observability-551372961758-ap-northeast-2-an"
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
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ReadRecommendationParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "${local.parameter_arn}/cking/prod-recommendation/*"
      },
    ], local.app_agent_statements)
  })
}

resource "aws_iam_instance_profile" "recommendation" {
  name = "prod-cking-recommendation-role"
  role = aws_iam_role.recommendation.name
}
