resource "aws_iam_role" "infra_deploy" {
  name = "dev-cking-infra-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-Infra@1406210898:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "observability_deploy" {
  name = "dev-cking-observability-deploy"
  role = aws_iam_role.infra_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListConfig"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.observability.arn
        Condition = { StringLike = { "s3:prefix" = ["config/", "config/*"] } }
      },
      {
        Sid      = "WriteConfig"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.observability.arn}/config/*"
      },
      {
        Sid      = "SendDeployCommand"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = [aws_instance.observability.arn, "arn:aws:ssm:ap-northeast-2::document/AWS-RunShellScript"]
      },
      {
        Sid      = "ReadCommandResult"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ec2:DescribeInstances"]
        Resource = "*"
      }
    ]
  })
}
