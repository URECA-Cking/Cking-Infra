# 댓글 필터 컨테이너 이미지. 개발에서 빌드한 이미지를 운영에도 그대로 올리므로 저장소는 하나이고, 오래 남는 개발 스택에 둔다.
# 모델 파일은 Git에 없어 개발 배포 버킷 filter/models/에 두고, 이미지 빌드 때 받아 이미지에 넣는다.

locals {
  comment_filter_function     = "dev-cking-comment-filter"
  comment_filter_function_arn = "arn:aws:lambda:ap-northeast-2:551372961758:function:${local.comment_filter_function}"
  deploy_bucket_arn           = "arn:aws:s3:::dev-cking-deploy-551372961758"
}

resource "aws_ecr_repository" "comment_filter" {
  name                 = "cking-comment-filter"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lambda는 이미지를 주기적으로 다시 받으므로 함수가 쓰는 이미지가 지워지면 함수가 Failed가 된다.
# 운영에 올린 이미지(prod- 태그)는 되돌리기용으로 따로 남기고, 나머지는 최근 것만 둔다.
resource "aws_ecr_lifecycle_policy" "comment_filter" {
  repository = aws_ecr_repository.comment_filter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "운영에 올린 이미지는 최근 10개"
        selection    = { tagStatus = "tagged", tagPrefixList = ["prod-"], countType = "imageCountMoreThan", countNumber = 10 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "태그 없는 이미지는 1일 뒤"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "나머지는 최근 10개"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
        action       = { type = "expire" }
      },
    ]
  })
}

# 같은 계정에서는 저장소 정책만으로 Lambda가 이미지를 받을 수 있다. 대상은 개발·운영 필터 함수뿐이다.
resource "aws_ecr_repository_policy" "comment_filter" {
  repository = aws_ecr_repository.comment_filter.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaImageRetrieval"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = { ArnLike = { "aws:sourceArn" = "arn:aws:lambda:ap-northeast-2:551372961758:function:*-cking-comment-filter" } }
    }]
  })
}

# 필터 저장소 CI: develop에서 모델을 받아 이미지를 빌드하고 올린 뒤 개발 Lambda를 그 이미지로 바꾸고, 함수 URL로 호출해 확인한다.
resource "aws_iam_role" "comment_filter_deploy" {
  name = "dev-cking-filter-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-Filtering-Benchmark@1399174039:ref:refs/heads/develop"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "comment_filter_deploy" {
  name = "dev-cking-filter-deploy"
  role = aws_iam_role.comment_filter_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListModel"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.deploy_bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["filter/models/", "filter/models/*"] } }
      },
      {
        Sid      = "ReadModel"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.deploy_bucket_arn}/filter/models/*"
      },
      {
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
          "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.comment_filter.arn
      },
      {
        Sid      = "UpdateDevFunction"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration"]
        Resource = local.comment_filter_function_arn
      },
      {
        Sid      = "InvokeDevFunction"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunctionUrl", "lambda:InvokeFunction"]
        Resource = local.comment_filter_function_arn
      },
    ]
  })
}

# 개발 필터 Lambda. 처음 이미지는 필터 저장소 develop 첫 CI(8a2cded)가 올린 것이고, 이후 이미지는 CI가 바꾸므로 Terraform은 비교하지 않는다.
# 메모리는 측정 최대 약 962MB에 2배 여유. 실행 상한에 걸리면 기동을 처음부터 다시 하므로, 측정한 콜드 스타트 최대 53.5초에 2배 여유를 둔다.
resource "aws_cloudwatch_log_group" "comment_filter" {
  name              = "/aws/lambda/${local.comment_filter_function}"
  retention_in_days = 14
}

resource "aws_iam_role" "comment_filter_function" {
  name = "dev-cking-comment-filter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "comment_filter_function" {
  name = "dev-cking-comment-filter-logs"
  role = aws_iam_role.comment_filter_function.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "WriteLogs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.comment_filter.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "comment_filter" {
  function_name = local.comment_filter_function
  role          = aws_iam_role.comment_filter_function.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.comment_filter.repository_url}@sha256:5e646701ee3e1240fdf6a6152d5dc7bb7c2da94560c8c9396b3e6d7582dc0d00"
  architectures = ["arm64"]
  memory_size   = 2048
  timeout       = 120

  # 개발 BE 판정 스레드 2개 × 앱 서버 1대. 운영과 같이 쓰는 계정 동시성을 그 이상 쓰지 않게 묶는다.
  reserved_concurrent_executions = 2

  depends_on = [aws_cloudwatch_log_group.comment_filter, aws_iam_role_policy.comment_filter_function]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

# 별칭 없이 $LATEST에 붙인다. CI가 바꾼 이미지가 바로 호출된다.
resource "aws_lambda_function_url" "comment_filter" {
  function_name      = aws_lambda_function.comment_filter.function_name
  authorization_type = "AWS_IAM"
}
