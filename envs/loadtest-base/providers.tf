provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = ["551372961758"]

  default_tags {
    tags = {
      Project   = "cking"
      Env       = "loadtest"
      ManagedBy = "terraform"
      Repo      = "URECA-Cking/Cking-Infra"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}
