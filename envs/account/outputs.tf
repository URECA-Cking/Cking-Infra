output "route53_name_servers" {
  description = "등록기관(가비아)에 넣을 cking.co.kr 네임서버"
  value       = aws_route53_zone.main.name_servers
}

output "certificates" {
  description = "*.cking.co.kr 인증서(ALB용 서울, CloudFront용 us-east-1)"
  value = {
    regional   = aws_acm_certificate_validation.regional.certificate_arn
    cloudfront = aws_acm_certificate_validation.cloudfront.certificate_arn
  }
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
