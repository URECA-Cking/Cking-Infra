module "k6" {
  source = "../../modules/k6-server"

  name                        = "${var.env_name}-cking-k6"
  vpc_id                      = data.aws_vpc.main.id
  subnet_id                   = data.aws_subnet.public_2a.id
  associate_public_ip_address = true
  ami                         = data.aws_instance.dev_app.ami
  instance_profile            = data.aws_iam_instance_profile.k6.name
  instance_type               = var.k6_instance_type
  gateway_ip                  = data.aws_instance.observability.private_ip
}

# k6 결과 지표와 k6 서버 지표를 관측 서버 관문으로 보낸다.
resource "aws_vpc_security_group_ingress_rule" "observability_metrics_from_k6" {
  security_group_id            = data.aws_security_group.observability.id
  description                  = "${var.env_name}-cking-k6 metrics"
  ip_protocol                  = "tcp"
  from_port                    = 9009
  to_port                      = 9009
  referenced_security_group_id = module.k6.security_group_id
}
