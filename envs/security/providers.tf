locals {
  default_tags = {
    Project   = "cking"
    Env       = "account"
    ManagedBy = "terraform"
    Repo      = "URECA-Cking/Cking-Infra"
  }
}

provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = ["551372961758"]

  default_tags {
    tags = local.default_tags
  }
}
