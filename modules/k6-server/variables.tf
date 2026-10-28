variable "name" {
  description = "서버 이름표. 관측 서버의 instance 라벨로도 쓴다"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "associate_public_ip_address" {
  description = "퍼블릭 서브넷이면 true. 프라이빗 서브넷이면 false로 두고 NAT로 나간다"
  type        = bool
}

variable "ami" {
  type = string
}

variable "instance_profile" {
  description = "SSM 접속과 JWT 비밀값 읽기만 허용한 인스턴스 프로필"
  type        = string
}

variable "gateway_ip" {
  description = "관측 서버 관문 주소. k6 결과 지표와 서버 지표를 여기로 보낸다"
  type        = string
}

variable "instance_type" {
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

variable "awscli_version" {
  description = "AWS CLI v2 버전. Ubuntu 26 apt의 awscli(Python 3.14)는 ssm send-command가 'badly formed help string'으로 실패해 공식 설치본을 쓴다"
  type        = string
  default     = "2.31.35"
}

variable "awscli_sha256" {
  description = "awscli-exe-linux-aarch64-<버전>.zip의 SHA-256. AWS가 체크섬을 따로 내지 않아 awscli.amazonaws.com에서 받은 파일로 계산했다"
  type        = string
  default     = "4cd25765c70e1bbd12d34b72d024c5a399f7c430108dc006fabeeac81fe3c418"
}
