# 개발 앱 서버와 추천 배치 서버가 함께 쓰는 값. 운영 서버(envs/prod/servers.tf)와 같은 AMI·Docker 버전으로 맞춘다.

locals {
  # ubuntu-resolute-26.04-arm64-server-20260604 (Canonical)
  server_ami = "ami-019e063f3fff5d27f"

  docker_versions = {
    docker_version     = "5:29.8.1-1~ubuntu.26.04~resolute"
    containerd_version = "2.3.5-1~ubuntu.26.04~resolute"
    compose_version    = "5.5.1-1~ubuntu.26.04~resolute"
  }
}
