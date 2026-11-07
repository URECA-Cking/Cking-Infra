# 개발 버킷은 TLS가 아닌 요청을 모두 거부한다(Security Hub S3.5). 운영 버킷은 envs/prod에서 같다.

locals {
  tls_buckets = {
    uploads  = aws_s3_bucket.uploads.arn
    admin    = aws_s3_bucket.admin_frontend.arn
    frontend = aws_s3_bucket.frontend.arn
    deploy   = aws_s3_bucket.deploy.arn
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
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn } }
      },
      local.deny_insecure_transport["frontend"],
    ]
  })
}

resource "aws_s3_bucket_policy" "deploy" {
  bucket = aws_s3_bucket.deploy.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.deny_insecure_transport["deploy"]]
  })
}
