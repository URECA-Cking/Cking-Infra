# 운영 댓글 필터 Lambda. 이미지 저장소는 개발 스택에 하나만 둔다(envs/dev/comment_filter.tf). 개발 CI가 확인하고 올린 이미지를
# 필터 저장소 main CI가 그대로 올린다. 처음 이미지는 개발 Lambda가 쓰는 이미지(필터 저장소 develop 8a2cded)이고, 이후는 CI가 바꾼다.

locals {
  comment_filter_function = "prod-cking-comment-filter"
}

data "aws_ecr_repository" "comment_filter" {
  name = "cking-comment-filter"
}

resource "aws_cloudwatch_log_group" "comment_filter" {
  name              = "/aws/lambda/${local.comment_filter_function}"
  retention_in_days = 14
}

resource "aws_iam_role" "comment_filter_function" {
  name = "prod-cking-comment-filter-role"

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
  name = "prod-cking-comment-filter-logs"
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

# 메모리·실행 상한은 개발과 같다(개발 측정 최대 메모리 약 962MB, 콜드 스타트 최대 53.5초에 각각 2배 여유).
resource "aws_lambda_function" "comment_filter" {
  function_name = local.comment_filter_function
  role          = aws_iam_role.comment_filter_function.arn
  package_type  = "Image"
  image_uri     = "${data.aws_ecr_repository.comment_filter.repository_url}@sha256:5e646701ee3e1240fdf6a6152d5dc7bb7c2da94560c8c9396b3e6d7582dc0d00"
  architectures = ["arm64"]
  memory_size   = 2048
  timeout       = 120

  # 운영 BE 판정 스레드 2개 × 앱 서버 최대 4대.
  reserved_concurrent_executions = 8

  depends_on = [aws_cloudwatch_log_group.comment_filter, aws_iam_role_policy.comment_filter_function]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_function_url" "comment_filter" {
  function_name      = aws_lambda_function.comment_filter.function_name
  authorization_type = "AWS_IAM"
}
