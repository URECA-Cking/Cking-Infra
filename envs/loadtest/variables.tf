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


variable "ttl_hours" {
  description = "켜진 뒤 이 시간이 지나면 정리기가 서버·RDS를 멈춘다. 가장 길었던 실행(운영 3차 7시간 20분)과 apply·배포 약 20분에 여유를 둔 값. 더 긴 측정이면 늘려서 apply한다"
  type        = number
  default     = 12
}
