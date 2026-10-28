resource "aws_s3_bucket_policy" "uploads" {
  bucket = data.aws_s3_bucket.uploads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontReadProfileImages"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource = [
          "${data.aws_s3_bucket.uploads.arn}/member-profile-images/*",
          "${data.aws_s3_bucket.uploads.arn}/creator-space-profile-images/*",
        ]
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.uploads.arn } }
      },
      local.deny_insecure_transport["uploads"],
    ]
  })
}

resource "aws_wafv2_web_acl" "uploads" {
  provider = aws.us_east_1
  name     = "dev-cking-uploads"
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
    metric_name                = "dev-cking-uploads"
  }
}

resource "aws_cloudfront_origin_access_control" "uploads" {
  name                              = "dev-cking-uploads"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "uploads" {
  enabled         = true
  comment         = "Dev uploads public images (S3 + CloudFront)"
  aliases         = ["dev-images.cking.co.kr"]
  http_version    = "http2"
  is_ipv6_enabled = true
  web_acl_id      = aws_wafv2_web_acl.uploads.arn

  origin {
    origin_id                = "uploads-s3"
    domain_name              = data.aws_s3_bucket.uploads.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads.id
  }

  default_cache_behavior {
    target_origin_id           = "uploads-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
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

resource "awscc_pricingplanmanager_subscription" "uploads" {
  plan_family   = "CloudFront"
  plan_tier     = "FREE"
  resource_arns = [aws_cloudfront_distribution.uploads.arn, aws_wafv2_web_acl.uploads.arn]
}

resource "aws_route53_record" "uploads" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev-images.cking.co.kr"
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.uploads.domain_name
    zone_id                = aws_cloudfront_distribution.uploads.hosted_zone_id
    evaluate_target_health = false
  }
}
