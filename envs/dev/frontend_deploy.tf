import {
  to = aws_iam_role.frontend_deploy
  id = "dev-cking-fe-github-actions-role"
}

import {
  to = aws_iam_role_policy.frontend_deploy
  id = "dev-cking-fe-github-actions-role:dev-cking-fe-deploy"
}

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
