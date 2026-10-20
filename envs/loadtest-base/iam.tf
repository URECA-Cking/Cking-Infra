# 부하 테스트 EC2가 쓰는 역할. 서버와 같은 apply로 만들면 전파 전에 부팅해 SSM 에이전트가 자격 증명을 받지 못해 따로 먼저 만든다.
# 테스트 환경을 지워도 남긴다. 이름은 envs/loadtest가 그대로 가리킨다.
locals {
  parameter_arn        = "arn:aws:ssm:ap-northeast-2:551372961758:parameter"
  deploy_bucket        = "dev-cking-deploy-551372961758"
  observability_bucket = "dev-cking-observability-551372961758-ap-northeast-2-an"

  ec2_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "app" {
  name               = "loadtest-cking-app-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "loadtest-cking-app-deploy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadEnvParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "${local.parameter_arn}/cking/loadtest/*"
      },
      {
        Sid      = "ReadDeployFiles"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${local.deploy_bucket}/releases/*"
      },
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
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "loadtest-cking-app-role"
  role = aws_iam_role.app.name
}

resource "aws_iam_role" "k6" {
  name               = "loadtest-cking-k6-role"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_role_policy_attachment" "k6_ssm" {
  role       = aws_iam_role.k6.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# k6가 실행 중에 Access Token을 직접 서명하도록 JWT 비밀값 하나만 읽는다.
# SecureString의 기본 키(aws/ssm)는 키 정책이 SSM을 거친 복호화를 허용해 KMS 권한을 따로 주지 않는다(앱 서버 역할과 같다).
resource "aws_iam_role_policy" "k6" {
  name = "loadtest-cking-k6-read-jwt-secret"
  role = aws_iam_role.k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadJwtSecret"
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = "${local.parameter_arn}/cking/loadtest/JWT_SECRET"
    }]
  })
}

resource "aws_iam_instance_profile" "k6" {
  name = "loadtest-cking-k6-role"
  role = aws_iam_role.k6.name
}
