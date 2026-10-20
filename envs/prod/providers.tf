locals {
  default_tags = {
    Project   = "cking"
    Env       = "prod"
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

# CloudFront 인증서는 us-east-1에 있다.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = ["551372961758"]

  default_tags {
    tags = local.default_tags
  }
}
