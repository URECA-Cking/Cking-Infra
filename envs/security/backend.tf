terraform {
  backend "s3" {
    bucket       = "dev-cking-tfstate-551372961758-ap-northeast-2-an"
    key          = "security/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
