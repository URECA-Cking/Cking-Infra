resource "aws_iam_role" "frontend_deploy" {
  name = "dev-cking-fe-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-FE@1362291094:ref:refs/heads/develop"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "frontend_deploy" {
  name = "dev-cking-fe-deploy"
  role = aws_iam_role.frontend_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SyncFrontendBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [data.aws_s3_bucket.frontend.arn, "${data.aws_s3_bucket.frontend.arn}/*"]
      },
      {
        Sid      = "InvalidateCache"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = data.aws_cloudfront_distribution.frontend.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "admin_frontend_deploy" {
  name = "dev-cking-fe-deploy-admin"
  role = aws_iam_role.frontend_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SyncAdminFrontendBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.admin_frontend.arn, "${aws_s3_bucket.admin_frontend.arn}/*"]
      },
      {
        Sid      = "InvalidateAdminFrontendCache"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.admin_frontend.arn
      }
    ]
  })
}
