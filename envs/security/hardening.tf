# Security Hub(FSBP) 지적 중 비용이 거의 없고 서비스 동작을 바꾸지 않는 계정 설정.

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_snapshot_block_public_access" "this" {
  state = "block-all-sharing"
}

# 모든 버킷이 이미 버킷 단위로 막혀 있고 CloudFront는 OAC로 읽어 공개 버킷이 없다.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

# 기본 보안 그룹은 어디에도 붙어 있지 않다. 규칙을 비워 실수로 붙어도 열리지 않게 한다.
data "aws_vpcs" "all" {}

resource "aws_default_security_group" "this" {
  for_each = toset(data.aws_vpcs.all.ids)

  vpc_id = each.value
}

data "aws_vpc" "named" {
  for_each = toset(["dev-cking-vpc", "prod-cking-vpc"])

  tags = { Name = each.value }
}

resource "aws_flow_log" "vpc" {
  for_each = data.aws_vpc.named

  vpc_id               = each.value.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${aws_s3_bucket.audit.arn}/flow-logs/"
  tags                 = { Name = "${each.key}-flow-log" }

  depends_on = [aws_s3_bucket_policy.audit]
}

resource "aws_inspector2_enabler" "this" {
  account_ids    = [local.account_id]
  resource_types = ["EC2", "ECR", "LAMBDA"]
}
