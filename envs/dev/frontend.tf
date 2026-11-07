# 사용자 앱 정적 호스팅. 관리자 앱(admin_frontend.tf)과 같이 OAC로 이 배포만 버킷을 읽고, 무료 요금제에 전용 WAF를 붙인다.
# SPA 경로는 S3에 객체가 없어 OAC에서 403이 오므로 403·404를 모두 /index.html 200으로 돌린다.

resource "aws_wafv2_web_acl" "frontend" {
  provider = aws.us_east_1
  name     = "dev-cking-frontend"
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
    metric_name                = "dev-cking-frontend"
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "dev-cking-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  comment             = "Dev frontend (S3 + CloudFront)"
  aliases             = ["dev.cking.co.kr"]
  default_root_object = "index.html"
  http_version        = "http2"
  is_ipv6_enabled     = true
  web_acl_id          = aws_wafv2_web_acl.frontend.arn

  origin {
    origin_id                = "frontend-s3"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id           = "frontend-s3"
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

resource "awscc_pricingplanmanager_subscription" "frontend" {
  plan_family   = "CloudFront"
  plan_tier     = "FREE"
  resource_arns = [aws_cloudfront_distribution.frontend.arn, aws_wafv2_web_acl.frontend.arn]
}

resource "aws_route53_record" "frontend" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev.cking.co.kr"
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}
