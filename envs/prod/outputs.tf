output "network" {
  value = {
    vpc_id         = aws_vpc.main.id
    subnet_ids     = { for k, s in aws_subnet.this : k => s.id }
    nat_public_ips = [for e in aws_eip.nat : e.public_ip]
  }
}

output "app" {
  value = {
    alb_dns_name   = aws_lb.main.dns_name
    asg_name       = aws_autoscaling_group.app.name
    be_deploy_role = aws_iam_role.be_deploy.arn
    deploy_bucket  = aws_s3_bucket.this["deploy"].id
    waf_log_group  = module.api_waf.log_group_name
  }
}
