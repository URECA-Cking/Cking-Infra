# 운영 버킷: 배포 파일(BE releases/, 추천 배치 recommendation/), 업로드 이미지, ALB 접근 로그, 웹·관리자 프론트.
# 이름은 prod-base 역할 정책이 가리키는 이름과 같다. 설정은 개발 관측 버킷과 같은 기본값(공개 차단, SSE-S3, TLS만)을 쓴다.

locals {
  buckets = {
    deploy   = "prod-cking-deploy-551372961758-ap-northeast-2-an"
    uploads  = "prod-cking-uploads-551372961758-ap-northeast-2-an"
    alb_logs = "prod-cking-alb-logs-551372961758-ap-northeast-2-an"
    web      = "prod-cking-frontend-551372961758-ap-northeast-2-an"
    admin    = "prod-cking-admin-551372961758-ap-northeast-2-an"
  }

  # ALB 접근 로그는 SSE-S3만 지원한다. 로그 보존은 앱 로그(Loki)와 같은 14일.
  alb_log_retention_days = 14
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket           = each.value
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      ], each.key == "alb_logs" ? [{
        Sid       = "AllowAlbAccessLogs"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this[each.key].arn}/AWSLogs/551372961758/*"
        Condition = { ArnLike = { "aws:SourceArn" = "arn:aws:elasticloadbalancing:ap-northeast-2:551372961758:loadbalancer/*" } }
      }] : [],
      contains(keys(local.cdn_bucket_reads), each.key) ? [{
        Sid       = "AllowCloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = [for p in local.cdn_bucket_reads[each.key].paths : "${aws_s3_bucket.this[each.key].arn}/${p}"]
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.this[local.cdn_bucket_reads[each.key].cdn].arn } }
    }] : [])
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.this[each.key].id

  rule {
    id     = "abort-incomplete-multipart-7d"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = each.key == "alb_logs" ? [local.alb_log_retention_days] : []

    content {
      id     = "expire-${rule.value}d"
      status = "Enabled"
      filter {}

      expiration {
        days = rule.value
      }
    }
  }
}
