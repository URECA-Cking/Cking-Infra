locals {
  default_tags = {
    Project   = "cking"
    Env       = "dev"
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

provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = ["551372961758"]

  default_tags {
    tags = local.default_tags
  }
}

provider "awscc" {
  region = "us-east-1"
}
