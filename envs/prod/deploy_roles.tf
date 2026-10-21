# GitHub Actions 운영 배포 역할(BE, FE, 댓글 필터). 저장소의 main 브랜치에서만 쓸 수 있고, 각 역할은 자기 자원만 다룬다.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# BE: 배포 파일 업로드 → 배포 태그 갱신 → 앱 서버 교체 시작. 수동 되돌리기도 같은 역할로 같은 단계를 거친다.
resource "aws_iam_role" "be_deploy" {
  name = "prod-cking-be-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-BE@1362263486:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "be_deploy" {
  name = "prod-cking-be-deploy"
  role = aws_iam_role.be_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 읽기는 수동 되돌리기에서 예전 태그의 배포 파일이 있는지 확인할 때 쓴다.
      {
        Sid      = "ReleaseFiles"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.this["deploy"].arn}/releases/*"
      },
      {
        Sid      = "SetReleaseTag"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/prod/RELEASE_TAG"
      },
      {
        Sid      = "RefreshAppServers"
        Effect   = "Allow"
        Action   = ["autoscaling:StartInstanceRefresh", "autoscaling:CancelInstanceRefresh"]
        Resource = aws_autoscaling_group.app.arn
      },
      # 서버 시작 시각은 교체가 실패했을 때 이미 새 버전으로 바뀐 서버를 찾는 데 쓴다(BE scripts/prod-recover.sh).
      {
        Sid      = "WatchRefresh"
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeInstanceRefreshes", "autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances"]
        Resource = "*"
      },
    ]
  })
}

# FE: 웹·관리자 빌드를 각 버킷에 동기화하고 캐시를 무효화한다.
resource "aws_iam_role" "fe_deploy" {
  name = "prod-cking-fe-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-FE@1362291094:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fe_deploy" {
  name = "prod-cking-fe-deploy"
  role = aws_iam_role.fe_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SyncFrontendBuckets"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = flatten([for k in ["web", "admin"] : [aws_s3_bucket.this[k].arn, "${aws_s3_bucket.this[k].arn}/*"]])
      },
      {
        Sid      = "InvalidateFrontendCache"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = [for k in ["web", "admin"] : aws_cloudfront_distribution.this[k].arn]
      },
    ]
  })
}

# 필터: 개발 CI가 확인하고 올린 이미지에 prod- 태그를 붙여 운영 Lambda로 바꾸고, 함수 URL로 호출해 확인한다. 이미지는 새로 올리지 않는다.
resource "aws_iam_role" "filter_deploy" {
  name = "prod-cking-filter-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-Filtering-Benchmark@1399174039:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "filter_deploy" {
  name = "prod-cking-filter-deploy"
  role = aws_iam_role.filter_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TagImage"
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:PutImage"]
        Resource = data.aws_ecr_repository.comment_filter.arn
      },
      {
        Sid      = "UpdateProdFunction"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetFunctionUrlConfig"]
        Resource = aws_lambda_function.comment_filter.arn
      },
      {
        Sid      = "InvokeProdFunction"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunctionUrl", "lambda:InvokeFunction"]
        Resource = aws_lambda_function.comment_filter.arn
      },
    ]
  })
}
