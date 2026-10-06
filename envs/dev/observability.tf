resource "aws_security_group" "observability" {
  name        = "dev-cking-observability-sg"
  description = "Observability server"
  vpc_id      = data.aws_vpc.main.id
  tags        = { Name = "dev-cking-observability-sg" }
}

resource "aws_vpc_security_group_egress_rule" "observability_https" {
  security_group_id = aws_security_group.observability.id
  description       = "Docker images, AWS APIs, webhooks"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "observability_http" {
  security_group_id = aws_security_group.observability.id
  description       = "Ubuntu package mirrors"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "observability" {
  name = "dev-cking-observability-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "observability" {
  name = "dev-cking-observability"
  role = aws_iam_role.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SsmAgent"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ]
        Resource = "*"
      },
      {
        Sid      = "MonitoringParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev/monitoring/*"
      },
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions",
          "ec2:DescribeTags",
          "tag:GetResources"
        ]
        Resource = "*"
      },
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.observability.arn
      },
      {
        Sid      = "ReadConfig"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.observability.arn}/config/*"
      },
      {
        Sid      = "LokiObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.observability.arn}/loki/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "observability" {
  name = "dev-cking-observability-role"
  role = aws_iam_role.observability.name
}

resource "aws_instance" "observability" {
  ami                         = "ami-01e3230cee0cae555"
  instance_type               = "t4g.small"
  subnet_id                   = data.aws_subnet.public_2b.id
  vpc_security_group_ids      = [aws_security_group.observability.id]
  iam_instance_profile        = aws_iam_instance_profile.observability.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/observability-init.sh", {
    data_volume_serial = replace(aws_ebs_volume.observability_data.id, "-", "")
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    tags        = { Name = "dev-cking-observability-root" }
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  tags = { Name = "dev-cking-observability" }
}

resource "aws_ebs_volume" "observability_data" {
  availability_zone = data.aws_subnet.public_2b.availability_zone
  type              = "gp3"
  size              = 10
  encrypted         = true
  tags              = { Name = "dev-cking-observability-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "observability_data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.observability_data.id
  instance_id                    = aws_instance.observability.id
  stop_instance_before_detaching = true
}

resource "aws_iam_role" "dlm" {
  name = "dev-cking-dlm-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dlm.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "observability_data" {
  description        = "dev-cking observability data daily"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Name = "dev-cking-observability-data" }

    schedule {
      name      = "daily-keep-7"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["18:00"]
      }

      retain_rule {
        count = 7
      }
    }
  }
}

resource "aws_s3_bucket" "observability" {
  bucket           = "dev-cking-observability-551372961758-ap-northeast-2-an"
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_ownership_controls" "observability" {
  bucket = aws_s3_bucket.observability.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "observability" {
  bucket                  = aws_s3_bucket.observability.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "observability" {
  bucket = aws_s3_bucket.observability.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_policy" "observability" {
  bucket = aws_s3_bucket.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.observability.arn, "${aws_s3_bucket.observability.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "observability" {
  bucket = aws_s3_bucket.observability.id

  rule {
    id     = "abort-incomplete-multipart-7d"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
