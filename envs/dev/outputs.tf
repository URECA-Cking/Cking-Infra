output "existing" {
  description = "Terraform이 읽어 온 기존 리소스"
  value = {
    vpc_id             = data.aws_vpc.main.id
    public_subnet_2b   = data.aws_subnet.public_2b.id
    app_sg_id          = data.aws_security_group.app.id
    alb_sg_id          = data.aws_security_group.alb.id
    alb_arn            = data.aws_lb.main.arn
    https_listener_arn = data.aws_lb_listener.https.arn
    route53_zone_id    = data.aws_route53_zone.main.zone_id
  }
}

output "admin_frontend" {
  description = "관리자 앱 배포에 필요한 값"
  value = {
    bucket          = aws_s3_bucket.admin_frontend.bucket
    distribution_id = aws_cloudfront_distribution.admin_frontend.id
    deploy_role_arn = aws_iam_role.frontend_deploy.arn
  }
}

output "observability" {
  description = "관측 서버 정보"
  value = {
    instance_id = aws_instance.observability.id
    private_ip  = aws_instance.observability.private_ip
    bucket      = aws_s3_bucket.observability.bucket
  }
}
