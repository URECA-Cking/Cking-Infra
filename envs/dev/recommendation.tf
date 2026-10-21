# 개발 추천 배치(콘텐츠 작업자). 운영 설계(#102)와 같이 배치 저장소 CI가 배포 패키지를 올리고 배포 버전 값을 바꾼 뒤
# 서버를 교체하면, 새 서버가 부팅하며 그 버전의 패키지를 받는다.

locals {
  recommendation_name          = "dev-cking-recommendation"
  recommendation_release_param = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev-recommendation/RELEASE"
  # 서버 그룹은 #136에서 만든다. 그 전에도 이 이름의 그룹만 교체할 수 있게 이름으로 한정한다.
  recommendation_asg_arn = "arn:aws:autoscaling:ap-northeast-2:551372961758:autoScalingGroup:*:autoScalingGroupName/${local.recommendation_name}"
}

# 배치 저장소 CI: develop에서 배포 패키지 업로드 → 배포 버전 값 갱신 → 서버 교체 시작.
resource "aws_iam_role" "recommendation_deploy" {
  name = "dev-cking-recommendation-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-LLM-Benchmark@1391984166:ref:refs/heads/develop"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "recommendation_deploy" {
  name = "dev-cking-recommendation-deploy"
  role = aws_iam_role.recommendation_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 같은 커밋을 다시 실행할 때 올려 둔 패키지가 있는지 본다. 목록 권한이 없으면 없는 파일도 403이라 구분하지 못한다.
      {
        Sid       = "ListReleases"
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.deploy_bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["recommendation/releases/", "recommendation/releases/*"] } }
      },
      {
        Sid      = "ReleasePackages"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${local.deploy_bucket_arn}/recommendation/releases/*"
      },
      # 읽기는 지금 배포된 버전이 이번 커밋보다 새로운지 비교할 때 쓴다.
      {
        Sid      = "SetRelease"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = local.recommendation_release_param
      },
      {
        Sid      = "RefreshServer"
        Effect   = "Allow"
        Action   = "autoscaling:StartInstanceRefresh"
        Resource = local.recommendation_asg_arn
      },
      {
        Sid      = "WatchRefresh"
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeInstanceRefreshes"]
        Resource = "*"
      },
    ]
  })
}
