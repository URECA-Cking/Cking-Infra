# 운영 부하 테스트용 k6 서버. 평소에는 만들지 않고 k6_enabled = true로 apply할 때만 만든다.
# 프라이빗 앱 서브넷에 두어 요청이 NAT IP로 나간다. 운영 WAF는 NAT IP를 허용 목록에 두므로(alb.tf)
# IP당 요청 제한에 걸리지 않고, 관측 서버는 앱 서브넷 대역을 받으므로(peering.tf) 규칙을 따로 두지 않는다.

variable "k6_enabled" {
  description = "운영 부하 테스트 동안만 true"
  type        = bool
  default     = false
}

variable "k6_instance_type" {
  description = "k6 서버 크기. CPU·메모리 포화나 dropped_iterations가 나오면 올린다"
  type        = string
  default     = "c7g.medium"
}

data "aws_instance" "observability" {
  count = var.k6_enabled ? 1 : 0

  filter {
    name   = "tag:Name"
    values = ["dev-cking-observability"]
  }
}

module "k6" {
  source = "../../modules/k6-server"
  count  = var.k6_enabled ? 1 : 0

  name                        = "prod-cking-k6"
  vpc_id                      = aws_vpc.main.id
  subnet_id                   = aws_subnet.this["app-2a"].id
  associate_public_ip_address = false
  ami                         = local.server_ami
  instance_profile            = "prod-cking-k6-role"
  instance_type               = var.k6_instance_type
  gateway_ip                  = data.aws_instance.observability[0].private_ip
}

output "k6_instance_id" {
  value = one(module.k6[*].instance_id)
}
