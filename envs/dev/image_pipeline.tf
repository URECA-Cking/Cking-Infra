# 이미지 업로드 이벤트 파이프라인. 브라우저가 업로드 버킷 raw/<최종 키>에 사전 서명 PUT으로 올리면
# S3 이벤트 → 작업 큐 → 정규화 Lambda → 최종 키 저장 → 결과 큐 → 앱이 업로드 기록을 완료로 바꾼다.
# 앱 안에서 정규화하면 2건/초부터 앱 컨테이너가 메모리 초과로 재시작됐다(2026-10-28 개발 서버 측정).

locals {
  image_pipeline_name   = "dev-cking-image"
  image_normalizer_name = "dev-cking-image-normalizer"
  image_normalizer_arn  = "arn:aws:lambda:ap-northeast-2:551372961758:function:${local.image_normalizer_name}"
  image_final_prefixes  = ["member-profile-images/", "creator-space-profile-images/", "post-images/"]
}

resource "aws_sqs_queue" "image_jobs_dlq" {
  name                      = "${local.image_pipeline_name}-jobs-dlq"
  message_retention_seconds = 1209600
}

# 보이지 않는 시간은 Lambda 실행 상한(60초)의 6배(AWS 권장).
resource "aws_sqs_queue" "image_jobs" {
  name                       = "${local.image_pipeline_name}-jobs"
  visibility_timeout_seconds = 360
  message_retention_seconds  = 86400
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.image_jobs_dlq.arn, maxReceiveCount = 3 })
}

resource "aws_sqs_queue_policy" "image_jobs" {
  queue_url = aws_sqs_queue.image_jobs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.image_jobs.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = data.aws_s3_bucket.uploads.arn }
        StringEquals = { "aws:SourceAccount" = "551372961758" }
      }
    }]
  })
}

resource "aws_sqs_queue" "image_results_dlq" {
  name                      = "${local.image_pipeline_name}-results-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "image_results" {
  name                       = "${local.image_pipeline_name}-results"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.image_results_dlq.arn, maxReceiveCount = 5 })
}

# 버킷은 콘솔이 관리하고 알림·CORS·수명 주기만 여기서 관리한다(버킷 정책과 같은 방식, uploads_cdn.tf).
resource "aws_s3_bucket_notification" "uploads" {
  bucket = data.aws_s3_bucket.uploads.id

  queue {
    queue_arn     = aws_sqs_queue.image_jobs.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
  }

  depends_on = [aws_sqs_queue_policy.image_jobs]
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = data.aws_s3_bucket.uploads.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["https://dev.cking.co.kr", "https://dev-admin.cking.co.kr"]
    allowed_headers = ["content-type", "x-amz-meta-min-width", "x-amz-meta-min-height"]
    max_age_seconds = 3000
  }
}

# 콘솔에서 만든 구독 인증 30일 규칙을 그대로 옮기고 raw/ 1일 규칙을 더한다.
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = data.aws_s3_bucket.uploads.id

  rule {
    id     = "expire-subscription-verifications-30d"
    status = "Enabled"
    filter {
      prefix = "subscription-verifications/"
    }
    expiration {
      days = 30
    }
  }

  rule {
    id     = "expire-raw-uploads-1d"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_cloudwatch_log_group" "image_normalizer" {
  name              = "/aws/lambda/${local.image_normalizer_name}"
  retention_in_days = 14
}

resource "aws_iam_role" "image_normalizer" {
  name = local.image_normalizer_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "image_normalizer" {
  name = local.image_normalizer_name
  role = aws_iam_role.image_normalizer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.image_normalizer.arn}:*"
      },
      {
        Sid      = "ReadRaw"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.uploads.arn}/raw/*"
      },
      {
        Sid      = "WriteFinal"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = [for p in local.image_final_prefixes : "${data.aws_s3_bucket.uploads.arn}/${p}*"]
      },
      {
        Sid      = "Jobs"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.image_jobs.arn
      },
      {
        Sid      = "Results"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.image_results.arn
      },
    ]
  })
}

# 20MP 원본 한 장 디코딩에 픽셀만 약 57MiB. 메모리를 늘리면 CPU도 늘어 처리 시간이 준다.
# 동시 실행 상한은 몰려도 큐에서 기다리게 해 비용과 버킷 쓰기 속도를 묶는다.
resource "aws_lambda_function" "image_normalizer" {
  function_name = local.image_normalizer_name
  role          = aws_iam_role.image_normalizer.arn
  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "handler.handler"
  s3_bucket     = "dev-cking-deploy-551372961758"
  s3_key        = "image-normalizer/initial.zip"
  memory_size   = 1536
  timeout       = 60

  reserved_concurrent_executions = 5

  environment {
    variables = {
      RESULTS_QUEUE_URL = aws_sqs_queue.image_results.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.image_normalizer, aws_iam_role_policy.image_normalizer]

  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

resource "aws_lambda_event_source_mapping" "image_jobs" {
  event_source_arn        = aws_sqs_queue.image_jobs.arn
  function_name           = aws_lambda_function.image_normalizer.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}

# 앱: raw/ 사전 서명 PUT(서명한 자격 증명에 쓰기 권한이 있어야 한다)과 결과 큐 읽기
resource "aws_iam_role_policy" "app_server_image_pipeline" {
  name = "dev-cking-ec2-image-pipeline"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PresignRaw"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${data.aws_s3_bucket.uploads.arn}/raw/*"
      },
      {
        Sid      = "Results"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.image_results.arn
      },
    ]
  })
}

resource "aws_ssm_parameter" "image_results_queue_url" {
  name  = "/cking/dev/IMAGE_PIPELINE_RESULTS_QUEUE_URL"
  type  = "String"
  value = aws_sqs_queue.image_results.id
}

resource "aws_cloudwatch_metric_alarm" "image_dlq" {
  for_each = {
    jobs    = aws_sqs_queue.image_jobs_dlq.name
    results = aws_sqs_queue.image_results_dlq.name
  }

  alarm_name          = "dev-cking-image-${each.key}-dlq"
  alarm_description   = "이미지 파이프라인 처리 실패가 DLQ에 쌓임. 런북: https://github.com/URECA-Cking/Cking-Infra/blob/main/docs/runbooks/image-pipeline-dlq.md"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Infra 저장소 CI가 image-normalizer/를 묶어 올리고 함수 코드를 바꾼다(deploy-image-normalizer.yml).
resource "aws_iam_role_policy" "image_normalizer_deploy" {
  name = "${local.image_normalizer_name}-deploy"
  role = aws_iam_role.infra_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Package"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.deploy_bucket_arn}/image-normalizer/*"
      },
      {
        Sid      = "UpdateFunction"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration"]
        Resource = local.image_normalizer_arn
      },
    ]
  })
}
