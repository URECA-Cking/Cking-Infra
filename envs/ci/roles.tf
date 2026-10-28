# Terraform plan·apply를 GitHub Actions에서 하는 역할(terraform-plan.yml, terraform-apply.yml).
# 공개 저장소라 PR 작성자가 워크플로를 고쳐 역할을 쓸 수 있다. 그래서 신뢰 조건을 GitHub Environment로 묶는다.
# Environment는 승인자가 있어 승인 전에는 작업이 시작되지 않고, Environment를 빼면 OIDC sub가 달라져 역할을 받지 못한다.

locals {
  repo_sub      = "repo:URECA-Cking@326738686/Cking-Infra@1406210898"
  state_bucket  = "dev-cking-tfstate-551372961758-ap-northeast-2-an"
  parameter_arn = "arn:aws:ssm:ap-northeast-2:551372961758:parameter"

  # plan이 data·ephemeral로 읽는 SecureString. 그 밖의 비밀값은 복호화하지 못한다.
  plan_secure_parameters = [
    "/cking/prod/GATE_SECRET",
    "/cking/prod/REDIS_PASSWORD",
    "/cking/prod-monitor/REDIS_PASSWORD",
    "/cking/dev/monitoring/GOOGLE_OAUTH_CLIENT_SECRET",
    "/cking/loadtest/DB_PASSWORD",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust" {
  for_each = toset(["terraform-plan", "terraform-apply"])

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.repo_sub}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "cking-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust["terraform-plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess는 데이터도 읽는다(업로드 이미지·구독 인증 화면, 로그, 큐 메시지, 경보 기록). plan은 설정만 읽으면 되므로 막는다.
data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "DecryptPlanSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.ap-northeast-2.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [for p in local.plan_secure_parameters : "${local.parameter_arn}${p}"]
    }
  }

  statement {
    sid           = "DenyObjectReadsExceptState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["arn:aws:s3:::${local.state_bucket}/*"]
  }

  statement {
    sid    = "DenyDataReads"
    effect = "Deny"
    actions = [
      "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:GetRecords",
      "sqs:ReceiveMessage",
      "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:StartLiveTail",
      "ssm:GetCommandInvocation", "ec2:GetPasswordData", "secretsmanager:GetSecretValue",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "cking-terraform-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

# apply는 IAM·네트워크·데이터베이스를 만들고 지워 관리자 권한이 필요하다. 대신 main에서만, 승인 뒤에만 받는다.
resource "aws_iam_role" "apply" {
  name                 = "cking-terraform-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust["terraform-apply"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
