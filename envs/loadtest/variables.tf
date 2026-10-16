variable "env_name" {
  description = "리소스 이름, Parameter Store 경로, 수집기 이름표에 쓰는 환경 이름"
  type        = string
  default     = "loadtest"
}

variable "instance_type" {
  description = "앱 서버 인스턴스 크기. 기준선은 개발 앱 서버와 같은 크기로 잰다"
  type        = string
  default     = "t4g.small"
}

variable "docker_version" {
  description = "docker-ce·docker-ce-cli 패키지 버전. 개발 앱 서버에 설치된 버전"
  type        = string
  default     = "5:29.8.1-1~ubuntu.26.04~resolute"
}

variable "containerd_version" {
  description = "containerd.io 패키지 버전. 개발 앱 서버에 설치된 버전"
  type        = string
  default     = "2.3.5-1~ubuntu.26.04~resolute"
}

variable "compose_version" {
  description = "docker-compose-plugin 패키지 버전. 개발 앱 서버에 설치된 버전"
  type        = string
  default     = "5.5.1-1~ubuntu.26.04~resolute"
}

variable "db_instance_class" {
  description = "RDS 크기. 기준선은 개발 RDS와 같은 크기로 잰다"
  type        = string
  default     = "db.t4g.micro"
}

variable "k6_instance_type" {
  description = "k6 서버 크기. 크레딧 방식이 아닌 종류로 고른다. CPU·메모리 포화나 dropped_iterations가 나오면 올린다"
  type        = string
  default     = "c7g.medium"
}

variable "k6_version" {
  description = "k6 버전(GitHub 릴리스 태그)"
  type        = string
  default     = "v2.3.0"
}

variable "k6_sha256" {
  description = "k6 linux-arm64 tar.gz의 SHA-256(릴리스 checksums.txt)"
  type        = string
  default     = "5ca3433e8201da72a284aaa241a1bb5fb47f4abb4e384d39410ddd8062f49b90"
}

variable "alloy_version" {
  description = "k6 서버 수집기 Alloy 버전. 앱 서버 수집기와 같은 버전"
  type        = string
  default     = "v1.20.1"
}

variable "alloy_sha256" {
  description = "alloy-linux-arm64.zip의 SHA-256(릴리스 SHA256SUMS)"
  type        = string
  default     = "396827d58158f181c98d5776c908348b38b4099f1d18a1e7554f2fda0fcb9203"
}
