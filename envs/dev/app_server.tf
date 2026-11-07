resource "aws_iam_role" "app_server" {
  name        = "dev-cking-ec2-role"
  description = "Allows EC2 instances to call AWS services on your behalf."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "app_server_deploy" {
  name = "dev-cking-ec2-deploy"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDevParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cking/dev/*"
      },
      {
        Sid      = "ReadDeployFiles"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.deploy.arn}/releases/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "app_server_uploads" {
  name = "dev-cking-ec2-uploads"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UploadObjects"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = [
          "${aws_s3_bucket.uploads.arn}/subscription-verifications/*",
          "${aws_s3_bucket.uploads.arn}/post-images/*",
          "${aws_s3_bucket.uploads.arn}/member-profile-images/*",
          "${aws_s3_bucket.uploads.arn}/creator-space-profile-images/*"
        ]
      },
      {
        Sid      = "NotFoundAs404"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.uploads.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_server_ssm" {
  role       = aws_iam_role.app_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app_server" {
  name = "dev-cking-ec2-role"
  role = aws_iam_role.app_server.name
}

resource "aws_iam_role_policy" "app_server_agent_config" {
  name = "dev-cking-ec2-app-agent"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListAppAgentConfig"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.observability.arn
        Condition = { StringLike = { "s3:prefix" = ["app-agent/", "app-agent/*"] } }
      },
      {
        Sid      = "ReadAppAgentConfig"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.observability.arn}/app-agent/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "app_server_comment_filter" {
  name = "dev-cking-ec2-comment-filter"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeCommentFilter"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunctionUrl", "lambda:InvokeFunction"]
      Resource = aws_lambda_function.comment_filter.arn
    }]
  })
}

# 앱과 Redis 컨테이너를 한 서버에 둔다. 첫 부팅은 운영 서버와 같은 공통 준비(envs/prod/templates/server-base.sh)만 하고,
# 앱은 BE CI가 배포한다. NAT가 없어 공인 IP로 나간다.
resource "aws_instance" "app" {
  ami                         = local.server_ami
  instance_type               = "t4g.small"
  subnet_id                   = aws_subnet.this["public_2a"].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app_server.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/app-init.sh", {
    server_base = templatefile("${path.module}/../prod/templates/server-base.sh", local.docker_versions)
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
    tags        = { Name = "dev-cking-app-root" }
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  # 첫 부팅 준비는 cloud-init이 처음에만 돌려, 공통 준비 스크립트가 바뀌어도 서버를 다시 띄울 이유가 없다.
  lifecycle {
    ignore_changes = [user_data]
  }

  tags = { Name = "dev-cking-app" }
}
