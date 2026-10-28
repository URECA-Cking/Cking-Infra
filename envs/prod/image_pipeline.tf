# 이미지 업로드 이벤트 파이프라인(개발 envs/dev/image_pipeline.tf와 같은 구성). 브라우저가 업로드 버킷 raw/<최종 키>에
# 사전 서명 PUT으로 올리면 S3 이벤트 → 작업 큐 → 정규화 Lambda → 최종 키 저장 → 결과 큐 → 앱이 업로드 기록을 완료로 바꾼다.
# 앱은 결과 큐 주소(Parameter Store)가 있을 때만 이 경로를 쓴다. 인프라를 먼저 만들고 켜기 전·후를 잰 뒤
# image_pipeline_enabled로 주소를 넣는다. 개발 측정 결과는 Infra #228·BE #780.

variable "image_pipeline_enabled" {
  description = "앱이 이미지 파이프라인을 쓰게 결과 큐 주소를 Parameter Store에 넣는다. 다음 앱 배포(서버 교체)부터 적용"
  type        = bool
  default     = false
}

locals {
  image_pipeline_name   = "prod-cking-image"
  image_normalizer_name = "prod-cking-image-normalizer"
  image_final_prefixes  = ["member-profile-images/", "creator-space-profile-images/", "post-images/"]
  # 묶음은 Infra main CI가 한 번 만들어 개발 배포 버킷에 올리고 개발·운영 함수에 같이 쓴다(댓글 필터 이미지와 같은 방식).
  image_normalizer_package_bucket = "dev-cking-deploy-551372961758"
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
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.this["uploads"].arn }
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

resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  queue {
    queue_arn     = aws_sqs_queue.image_jobs.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
  }

  depends_on = [aws_sqs_queue_policy.image_jobs]
}

# 사전 서명 PUT은 브라우저가 버킷에 직접 보낸다. www는 cking.co.kr로 넘어가므로 넣지 않는다.
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.this["uploads"].id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["https://cking.co.kr", "https://admin.cking.co.kr"]
    allowed_headers = ["content-type", "x-amz-meta-min-width", "x-amz-meta-min-height"]
    max_age_seconds = 3000
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
        Resource = "${aws_s3_bucket.this["uploads"].arn}/raw/*"
      },
      {
        Sid      = "WriteFinal"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = [for p in local.image_final_prefixes : "${aws_s3_bucket.this["uploads"].arn}/${p}*"]
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

# 메모리·실행 상한·동시성은 개발과 같다. 개발 측정: 처리 p95 0.58초·최대 0.80초, 메모리 최대 266MB(메모리를 늘리면
# CPU도 늘어 처리 시간이 준다), 동시 5에서 초당 약 7~8건. 큐 대기(가장 오래된 메시지)가 30초에 가까워지면 동시성을 올린다.
resource "aws_lambda_function" "image_normalizer" {
  function_name = local.image_normalizer_name
  role          = aws_iam_role.image_normalizer.arn
  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "handler.handler"
  s3_bucket     = local.image_normalizer_package_bucket
  s3_key        = "image-normalizer/afa06e414973480e70c691ef18550ea8b57af485.zip"
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
    ignore_changes = [s3_bucket, s3_key, s3_object_version, source_code_hash]
  }
}

# 예약 동시성만 두면 SQS 폴러가 그보다 많이 호출해 스로틀이 난다(개발 8건/초부터 분당 23~153건, Infra #228).
resource "aws_lambda_event_source_mapping" "image_jobs" {
  event_source_arn        = aws_sqs_queue.image_jobs.arn
  function_name           = aws_lambda_function.image_normalizer.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 5
  }
}

resource "aws_ssm_parameter" "image_results_queue_url" {
  count = var.image_pipeline_enabled ? 1 : 0

  name  = "/cking/prod/IMAGE_PIPELINE_RESULTS_QUEUE_URL"
  type  = "String"
  value = aws_sqs_queue.image_results.id
}

resource "aws_cloudwatch_metric_alarm" "image_dlq" {
  for_each = {
    jobs    = aws_sqs_queue.image_jobs_dlq.name
    results = aws_sqs_queue.image_results_dlq.name
  }

  alarm_name          = "prod-cking-image-${each.key}-dlq"
  alarm_description   = "이미지 파이프라인 처리 실패가 DLQ에 쌓임. 런북: ${local.alarm_runbook}/image-pipeline-dlq.md"
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
