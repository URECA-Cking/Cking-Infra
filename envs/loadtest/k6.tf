locals {
  k6_name = "${var.env_name}-cking-k6"
}

resource "aws_security_group" "k6" {
  name        = "${local.k6_name}-sg"
  description = "Load test k6 server"
  vpc_id      = data.aws_vpc.main.id
  tags        = { Name = "${local.k6_name}-sg" }
}

resource "aws_vpc_security_group_egress_rule" "k6_all" {
  security_group_id = aws_security_group.k6.id
  description       = "Load to ALB, downloads, AWS APIs, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# k6 결과 지표와 k6 서버 지표를 관측 서버 관문으로 보낸다.
resource "aws_vpc_security_group_ingress_rule" "observability_metrics_from_k6" {
  security_group_id            = data.aws_security_group.observability.id
  description                  = "${local.k6_name} metrics"
  ip_protocol                  = "tcp"
  from_port                    = 9009
  to_port                      = 9009
  referenced_security_group_id = aws_security_group.k6.id
}

resource "aws_iam_role" "k6" {
  name = "${local.k6_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "k6_ssm" {
  role       = aws_iam_role.k6.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# k6가 실행 중에 Access Token을 직접 서명하도록 JWT 비밀값 하나만 읽는다.
# SecureString의 기본 키(aws/ssm)는 키 정책이 SSM을 거친 복호화를 허용해 KMS 권한을 따로 주지 않는다(앱 서버 역할과 같다).
resource "aws_iam_role_policy" "k6" {
  name = "${local.k6_name}-read-jwt-secret"
  role = aws_iam_role.k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadJwtSecret"
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/${var.env_name}/JWT_SECRET"
    }]
  })
}

resource "aws_iam_instance_profile" "k6" {
  name = "${local.k6_name}-role"
  role = aws_iam_role.k6.name
}

resource "aws_instance" "k6" {
  ami                         = data.aws_instance.dev_app.ami
  instance_type               = var.k6_instance_type
  subnet_id                   = data.aws_subnet.public_2a.id
  vpc_security_group_ids      = [aws_security_group.k6.id]
  iam_instance_profile        = aws_iam_instance_profile.k6.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/k6-init.sh", {
    k6_version    = var.k6_version
    k6_sha256     = var.k6_sha256
    alloy_version = var.alloy_version
    alloy_sha256  = var.alloy_sha256
    instance      = local.k6_name
    gateway_ip    = data.aws_instance.observability.private_ip
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    tags        = { Name = "${local.k6_name}-root" }
  }

  tags = { Name = local.k6_name }
}
