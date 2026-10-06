resource "aws_s3_bucket" "admin_frontend" {
  bucket           = "dev-cking-admin-551372961758-ap-northeast-2-an"
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_ownership_controls" "admin_frontend" {
  bucket = aws_s3_bucket.admin_frontend.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "admin_frontend" {
  bucket                  = aws_s3_bucket.admin_frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "admin_frontend" {
  bucket = aws_s3_bucket.admin_frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_policy" "admin_frontend" {
  bucket = aws_s3_bucket.admin_frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontServicePrincipal"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.admin_frontend.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.admin_frontend.arn } }
    }]
  })
}

resource "aws_wafv2_web_acl" "admin_frontend" {
  provider = aws.us_east_1
  name     = "dev-cking-admin-frontend"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = ["AWSManagedRulesAmazonIpReputationList", "AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"]

    content {
      name     = "AWS-${rule.value}"
      priority = rule.key

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "AWS-${rule.value}"
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = "dev-cking-admin-frontend"
  }
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_origin_access_control" "admin_frontend" {
  name                              = "dev-cking-admin-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "admin_frontend" {
  enabled             = true
  comment             = "Dev admin frontend (S3 + CloudFront)"
  aliases             = ["dev-admin.cking.co.kr"]
  default_root_object = "index.html"
  http_version        = "http2"
  is_ipv6_enabled     = true
  web_acl_id          = aws_wafv2_web_acl.admin_frontend.arn

  origin {
    origin_id                = "admin-frontend-s3"
    domain_name              = aws_s3_bucket.admin_frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.admin_frontend.id
  }

  default_cache_behavior {
    target_origin_id           = "admin-frontend-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  dynamic "custom_error_response" {
    for_each = [403, 404]

    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.wildcard.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "awscc_pricingplanmanager_subscription" "admin_frontend" {
  plan_family   = "CloudFront"
  plan_tier     = "FREE"
  resource_arns = [aws_cloudfront_distribution.admin_frontend.arn, aws_wafv2_web_acl.admin_frontend.arn]
}

resource "aws_route53_record" "admin_frontend" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev-admin.cking.co.kr"
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.admin_frontend.domain_name
    zone_id                = aws_cloudfront_distribution.admin_frontend.hosted_zone_id
    evaluate_target_health = false
  }
}
