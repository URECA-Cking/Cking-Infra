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
