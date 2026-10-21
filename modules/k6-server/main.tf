# 부하 테스트 k6 서버. 부하 테스트 환경(envs/loadtest)과 운영(envs/prod)이 같이 쓴다.

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Load test k6 server"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-sg" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Load to ALB, downloads, AWS APIs, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "this" {
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = var.instance_profile
  associate_public_ip_address = var.associate_public_ip_address

  user_data = templatefile("${path.module}/k6-init.sh", {
    k6_version    = var.k6_version
    k6_sha256     = var.k6_sha256
    alloy_version = var.alloy_version
    alloy_sha256  = var.alloy_sha256
    instance      = var.name
    gateway_ip    = var.gateway_ip
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    tags        = { Name = "${var.name}-root" }
  }

  tags = { Name = var.name }
}
