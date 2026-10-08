import {
  to = aws_iam_role.app_server
  id = "dev-cking-ec2-role"
}

import {
  to = aws_iam_role_policy.app_server_deploy
  id = "dev-cking-ec2-role:dev-cking-ec2-deploy"
}

import {
  to = aws_iam_role_policy.app_server_uploads
  id = "dev-cking-ec2-role:dev-cking-ec2-uploads"
}

import {
  to = aws_iam_role_policy_attachment.app_server_ssm
  id = "dev-cking-ec2-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_instance_profile.app_server
  id = "dev-cking-ec2-role"
}

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
        Resource = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/dev/*"
      },
      {
        Sid      = "ReadDeployFiles"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::dev-cking-deploy-551372961758/releases/*"
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
          "arn:aws:s3:::dev-cking-uploads-551372961758-ap-northeast-2-an/subscription-verifications/*",
          "arn:aws:s3:::dev-cking-uploads-551372961758-ap-northeast-2-an/post-images/*"
        ]
      },
      {
        Sid      = "NotFoundAs404"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::dev-cking-uploads-551372961758-ap-northeast-2-an"
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
