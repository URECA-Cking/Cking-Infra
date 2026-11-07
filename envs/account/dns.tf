# 도메인 cking.co.kr의 공개 영역과 *.cking.co.kr 인증서. 개발·운영·부하 테스트가 이름으로 찾아 쓴다.
# 영역을 다시 만들면 네임서버가 바뀌어 등록기관(가비아)의 위임도 바꿔야 하므로 지우지 않는다.

resource "aws_route53_zone" "main" {
  #checkov:skip=CKV2_AWS_38:DNSSEC는 등록기관(가비아) DS 등록과 서명 키(KMS)가 필요해 켜지 않는다
  #checkov:skip=CKV2_AWS_39:조회 로그는 비용 대비 두지 않고 레코드 변경은 CloudTrail로 본다(envs/security/triage.tf accepted-logging)
  name = "cking.co.kr"

  lifecycle {
    prevent_destroy = true
  }
}

# 루트 도메인은 와일드카드에 들어가지 않아 함께 받는다. ALB는 같은 리전, CloudFront는 us-east-1 인증서만 쓴다.
locals {
  certificate_domain = "*.cking.co.kr"
  certificate_sans   = ["cking.co.kr"]
}

resource "aws_acm_certificate" "regional" {
  #checkov:skip=CKV2_AWS_71:dev-api·monitoring 같은 하이픈 호스트를 인증서 한 장으로 받는다(설계서 3.5)
  domain_name               = local.certificate_domain
  subject_alternative_names = local.certificate_sans
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "cloudfront" {
  #checkov:skip=CKV2_AWS_71:dev-api·monitoring 같은 하이픈 호스트를 인증서 한 장으로 받는다(설계서 3.5)
  provider                  = aws.us_east_1
  domain_name               = local.certificate_domain
  subject_alternative_names = local.certificate_sans
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# 와일드카드와 루트, 두 리전의 검증 레코드는 같은 이름·값이 나올 수 있어 덮어쓰기를 허용한다.
locals {
  certificate_validations = merge(
    { for o in aws_acm_certificate.regional.domain_validation_options : "regional ${o.domain_name}" => o },
    { for o in aws_acm_certificate.cloudfront.domain_validation_options : "cloudfront ${o.domain_name}" => o },
  )
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.certificate_validations

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "regional" {
  certificate_arn         = aws_acm_certificate.regional.arn
  validation_record_fqdns = [for k, r in aws_route53_record.certificate_validation : r.fqdn if startswith(k, "regional ")]
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for k, r in aws_route53_record.certificate_validation : r.fqdn if startswith(k, "cloudfront ")]
}
