# BE CI(develop): 배포 파일을 배포 버킷 releases/<태그>/에 올리고 SSM Run Command로 앱 서버의 deploy.sh를 실행한다.
# 쓰기만 갖고, 서버는 앱 서버 역할(app_server.tf)로 읽는다.
resource "aws_iam_role" "app_deploy" {
  name = "dev-cking-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:URECA-Cking@326738686/Cking-BE@1362263486:ref:refs/heads/develop"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "app_deploy" {
  name = "dev-cking-github-actions-deploy"
  role = aws_iam_role.app_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UploadRelease"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.deploy.arn}/releases/*"
      },
      {
        Sid      = "RunDeploy"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = [aws_instance.app.arn, "arn:aws:ssm:${local.region}::document/AWS-RunShellScript"]
      },
      {
        # 앱 서버는 다시 만들면 ID가 바뀐다. BE CI가 이름표로 ID를 찾는다. 이 액션은 리소스를 좁힐 수 없다.
        Sid      = "FindAppServer"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Sid      = "ReadCommandResult"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      }
    ]
  })
}
