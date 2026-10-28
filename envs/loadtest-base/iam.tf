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

# k6가 실행 중에 Access Token을 직접 서명하도록 JWT 비밀값을 읽는다.
# SecureString의 기본 키(aws/ssm)는 키 정책이 SSM을 거친 복호화를 허용해 KMS 권한을 따로 주지 않는다(앱 서버 역할과 같다).
# 실행기(loadtest/runner/ltrun.py)가 k6 서버에서 돌며 앱 서버에 데이터 작업을 보내고, 관측 서버 조회 문서로 지표를 읽고, 결과를 올린다.
# 앱 서버 명령은 이름표가 부하 테스트 앱 서버인 것에만 보낼 수 있다. DB·Redis 비밀번호는 앱 서버 역할이 읽는다.
# SendCommand는 인스턴스와 문서를 따로 허용해, 같은 역할에 관측 서버를 넣으면 관측 서버에서도 임의 셸이 된다.
# 그래서 지표 조회는 조회 문서·관측 서버만 허용한 역할(query)로 넘어가서 한다.
resource "aws_iam_role_policy" "k6" {
  name = "loadtest-cking-k6-read-jwt-secret"
  role = aws_iam_role.k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadJwtSecret"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.parameter_arn}/cking/loadtest/JWT_SECRET"
      },
      {
        Sid      = "ReadRunNotifyWebhook"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.parameter_arn}/cking/dev/monitoring/SLACK_ALERT_WEBHOOK_URL"
      },
      {
        Sid      = "RunOnLoadtestApp"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ec2:ap-northeast-2:551372961758:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = "loadtest-cking-app" }
        }
      },
      {
        Sid      = "RunShellDocument"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:ap-northeast-2::document/AWS-RunShellScript"
      },
      {
        Sid      = "AssumeQueryRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.query.arn
      },
      {
        Sid      = "ReadCommandResults"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "WriteResults"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.results.arn}/loadtest/*"
      },
      {
        Sid       = "ListResults"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.results.arn
        Condition = { StringLike = { "s3:prefix" = ["loadtest/*"] } }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "k6" {
  name = "loadtest-cking-k6-role"
  role = aws_iam_role.k6.name
}

# 실행기의 지표 요약 전용. 관측 서버 읽기 전용 조회 문서(dev-cking-observability-query)만 보낼 수 있다.
# 운영 k6 역할도 넘어올 수 있게 믿는다. 운영 k6 역할에 sts:AssumeRole을 줄 때 쓴다.
resource "aws_iam_role" "query" {
  name = "loadtest-cking-query"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [aws_iam_role.k6.arn, "arn:aws:iam::551372961758:role/prod-cking-k6-role"]
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "query" {
  name = "loadtest-cking-observability-query"
  role = aws_iam_role.query.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "QueryObservability"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:ap-northeast-2:551372961758:document/dev-cking-observability-query",
          "arn:aws:ec2:ap-northeast-2:551372961758:instance/*",
        ]
        Condition = {
          StringEqualsIfExists = { "ssm:resourceTag/Name" = "dev-cking-observability" }
        }
      },
      {
        Sid      = "ReadQueryResult"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      }
    ]
  })
}
