# 운영 프론트(웹·관리자)와 공개 이미지 CDN. 구성은 개발과 같되, CloudFront 무료 요금제 3자리를 개발이 모두 써서
# 종량제로 두고 WAF는 붙이지 않는다. 403·404 → index.html 규칙은 배포 전체에 걸리므로 이미지는 배포를 따로 둔다.

locals {
  cdn = {
    web = {
      bucket     = "web"
      aliases    = ["cking.co.kr", "www.cking.co.kr"]
      read_paths = ["*"]
      spa        = true
    }
    admin = {
      bucket     = "admin"
      aliases    = ["admin.cking.co.kr"]
      read_paths = ["*"]
      spa        = true
    }
    images = {
      bucket     = "uploads"
      aliases    = ["images.cking.co.kr"]
      read_paths = ["member-profile-images/*", "creator-space-profile-images/*"]
      spa        = false
    }
  }

  # 버킷 정책(buckets.tf)이 버킷 이름으로 찾는다.
  cdn_bucket_reads = { for k, v in local.cdn : v.bucket => { cdn = k, paths = v.read_paths } }

  cdn_records = merge([
    for k, v in local.cdn : {
      for pair in setproduct(v.aliases, ["A", "AAAA"]) : "${pair[0]}-${pair[1]}" => { cdn = k, name = pair[0], type = pair[1] }
    }
  ]...)
}

data "aws_acm_certificate" "cdn" {
  provider = aws.us_east_1
  domain   = "*.cking.co.kr"
  statuses = ["ISSUED"]
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_origin_access_control" "this" {
  for_each = local.cdn

  name                              = "prod-cking-${each.key}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# www.cking.co.kr은 같은 경로·쿼리로 cking.co.kr에 영구 이동한다. BE CORS 허용 목록에는 cking.co.kr만 둔다.
resource "aws_cloudfront_function" "www_redirect" {
  name    = "prod-cking-www-redirect"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/functions/www-redirect.js")
}

# 정식 오픈 전 웹·관리자를 비밀 쿠키 게이트 뒤에 둔다. 웹의 www 넘기기도 같은 함수가 한다(요청 단계 함수는 하나만 붙는다).
variable "gate_enabled" {
  type    = bool
  default = true
}

data "aws_ssm_parameter" "gate_secret" {
  name = "/cking/prod/GATE_SECRET"
}

resource "aws_cloudfront_function" "gate" {
  for_each = var.gate_enabled ? toset(["web", "admin"]) : toset([])

  name    = "prod-cking-${each.key}-gate"
  runtime = "cloudfront-js-2.0"
  publish = true
  code = templatefile("${path.module}/functions/gate.js.tftpl", {
    secret       = data.aws_ssm_parameter.gate_secret.value
    redirect_www = each.key == "web"
  })
}

locals {
  viewer_request_functions = {
    web    = var.gate_enabled ? aws_cloudfront_function.gate["web"].arn : aws_cloudfront_function.www_redirect.arn
    admin  = var.gate_enabled ? aws_cloudfront_function.gate["admin"].arn : null
    images = null
  }
}

resource "aws_cloudfront_distribution" "this" {
  for_each = local.cdn

  enabled             = true
  comment             = "Prod ${each.key} (S3 + CloudFront)"
  aliases             = each.value.aliases
  default_root_object = each.value.spa ? "index.html" : null
  http_version        = "http2"
  is_ipv6_enabled     = true

  origin {
    origin_id                = "${each.key}-s3"
    domain_name              = aws_s3_bucket.this[each.value.bucket].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this[each.key].id
  }

  default_cache_behavior {
    target_origin_id           = "${each.key}-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id

    dynamic "function_association" {
      for_each = local.viewer_request_functions[each.key] == null ? [] : [local.viewer_request_functions[each.key]]

      content {
        event_type   = "viewer-request"
        function_arn = function_association.value
      }
    }
  }

  dynamic "custom_error_response" {
    for_each = each.value.spa ? [403, 404] : []

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
    acm_certificate_arn      = data.aws_acm_certificate.cdn.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_route53_record" "cdn" {
  for_each = local.cdn_records

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.this[each.value.cdn].domain_name
    zone_id                = aws_cloudfront_distribution.this[each.value.cdn].hosted_zone_id
    evaluate_target_health = false
  }
}
