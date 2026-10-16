locals {
  name     = "${var.env_name}-cking-app"
  api_host = "${var.env_name}-api.cking.co.kr"
}

resource "aws_security_group" "app" {
  name        = "${local.name}-sg"
  description = "Load test app server"
  vpc_id      = data.aws_vpc.main.id
  tags        = { Name = "${local.name}-sg" }
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Image pull, AWS APIs, observability push"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "observability_metrics_from_app" {
  security_group_id            = data.aws_security_group.observability.id
  description                  = "${local.name} Alloy metrics"
  ip_protocol                  = "tcp"
  from_port                    = 9009
  to_port                      = 9009
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "observability_logs_from_app" {
  security_group_id            = data.aws_security_group.observability.id
  description                  = "${local.name} Alloy logs"
  ip_protocol                  = "tcp"
  from_port                    = 3500
  to_port                      = 3500
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_iam_role" "app" {
  name = "${local.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${local.name}-deploy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadEnvParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/${var.env_name}/*"
      },
      {
        Sid      = "ReadDeployFiles"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${data.aws_s3_bucket.deploy.arn}/releases/*"
      },
      {
        Sid       = "ListAppAgentConfig"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = data.aws_s3_bucket.observability.arn
        Condition = { StringLike = { "s3:prefix" = ["app-agent/", "app-agent/*"] } }
      },
      {
        Sid      = "ReadAppAgentConfig"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${data.aws_s3_bucket.observability.arn}/app-agent/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-role"
  role = aws_iam_role.app.name
}

resource "aws_instance" "app" {
  ami                         = data.aws_instance.dev_app.ami
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.public_2a.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/app-init.sh", {
    docker_version     = var.docker_version
    containerd_version = var.containerd_version
    compose_version    = var.compose_version
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
    tags        = { Name = "${local.name}-root" }
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  tags = { Name = local.name }
}
