# 업로드·사용자 앱·배포 버킷. 모두 퍼블릭 차단, ACL 비활성화, SSE-S3, 버전 관리 없음.
# 업로드 버킷은 계정 리전 네임스페이스이고, 사용자 앱·배포 버킷은 BE·FE·Lambda 배포가 이름으로 쓰는 글로벌 이름이다.
# 정책은 bucket_tls.tf·uploads_cdn.tf, 업로드 버킷의 알림·CORS·수명 주기는 image_pipeline.tf에 둔다.

resource "aws_s3_bucket" "uploads" {
  bucket           = "dev-cking-uploads-${local.account_id}-${local.region}-an"
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket" "frontend" {
  bucket = "dev-cking-frontend-${local.account_id}"
}

resource "aws_s3_bucket" "deploy" {
  bucket = "dev-cking-deploy-${local.account_id}"
}

locals {
  base_buckets = {
    uploads  = aws_s3_bucket.uploads.id
    frontend = aws_s3_bucket.frontend.id
    deploy   = aws_s3_bucket.deploy.id
  }
}

resource "aws_s3_bucket_ownership_controls" "base" {
  for_each = local.base_buckets

  bucket = each.value

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "base" {
  for_each = local.base_buckets

  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "base" {
  for_each = local.base_buckets

  bucket = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}
