provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = ["551372961758"]

  default_tags {
    tags = {
      Project   = "cking"
      Env       = var.env_name
      ManagedBy = "terraform"
      Repo      = "URECA-Cking/Cking-Infra"
      # envs/loadtest-base 정리기가 켜진 지 이 시간이 지난 서버·RDS를 멈춘다
      "cking:ttl-hours" = tostring(var.ttl_hours)
    }
  }
}
