provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = ["551372961758"]

  default_tags {
    tags = {
      Project   = "cking"
      Env       = "dev"
      ManagedBy = "terraform"
      Repo      = "URECA-Cking/Cking-Infra"
    }
  }
}
