# 실행기 결과(요청별 기록, 서버 출력, results.md). 공개 저장소·Actions 로그에 남기지 않는 원자료라 비공개 버킷에 둔다.
# 테스트 환경을 지워도 남아야 해서 base에 둔다. 1년 뒤 지운다(같은 계정의 감사 로그와 같은 기한).

locals {
  results_bucket = "loadtest-cking-results-551372961758-ap-northeast-2-an"
}

resource "aws_s3_bucket" "results" {
  bucket           = local.results_bucket
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-after-1-year"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket = aws_s3_bucket.results.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.results]
}
