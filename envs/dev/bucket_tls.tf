# 개발 버킷은 TLS가 아닌 요청을 모두 거부한다(Security Hub S3.5). 운영 버킷은 envs/prod에서 이미 같다.
# 웹 버킷 정책은 콘솔에서 만든 것을 그대로 옮기고(업로드 버킷과 같은 방식, Infra #38), 배포 버킷은 정책이 없어 새로 둔다.

locals {
  tls_buckets = {
    uploads  = data.aws_s3_bucket.uploads.arn
    admin    = aws_s3_bucket.admin_frontend.arn
    frontend = data.aws_s3_bucket.frontend.arn
    deploy   = "arn:aws:s3:::dev-cking-deploy-551372961758"
  }

  deny_insecure_transport = {
    for name, arn in local.tls_buckets : name => {
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [arn, "${arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = data.aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${data.aws_s3_bucket.frontend.arn}/*"
        Condition = { ArnLike = { "AWS:SourceArn" = data.aws_cloudfront_distribution.frontend.arn } }
      },
      local.deny_insecure_transport["frontend"],
    ]
  })
}

resource "aws_s3_bucket_policy" "deploy" {
  bucket = "dev-cking-deploy-551372961758"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.deny_insecure_transport["deploy"]]
  })
}
