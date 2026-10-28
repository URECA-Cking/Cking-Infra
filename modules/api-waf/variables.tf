variable "name" {
  type = string
}

variable "alb_arn" {
  type = string
}

variable "api_host" {
  description = "규칙을 적용할 API 호스트. 같은 ALB의 다른 호스트(Grafana 등)는 검사하지 않는다."
  type        = string
}

variable "mode" {
  description = "count는 세기만 하고, block은 막는다."
  type        = string

  validation {
    condition     = contains(["count", "block"], var.mode)
    error_message = "mode는 count 또는 block이다."
  }
}

variable "allow_ip_cidrs" {
  description = "모든 규칙을 건너뛰는 IP(운영 NAT 등)."
  type        = list(string)
  default     = []
}

variable "rate_limit" {
  description = "IP당 요청 수 상한. null이면 규칙을 만들지 않는다."
  type        = number
  default     = null

  validation {
    condition     = coalesce(var.rate_limit, 10) >= 10
    error_message = "rate_limit은 10 이상이다."
  }
}

variable "rate_window_sec" {
  type    = number
  default = 300

  validation {
    condition     = contains([60, 120, 300, 600], var.rate_window_sec)
    error_message = "rate_window_sec은 60, 120, 300, 600 중 하나다."
  }
}

variable "gate" {
  description = "비밀 쿠키 게이트. cking_gate 쿠키나 x-cking-gate 헤더가 secret과 같은 요청만 통과시킨다. null이면 규칙을 만들지 않는다."
  type = object({
    secret = string
    mode   = string
  })
  default = null

  validation {
    condition     = var.gate == null || contains(["count", "block"], try(var.gate.mode, ""))
    error_message = "gate.mode는 count 또는 block이다."
  }
}

variable "log_retention_days" {
  type = number
}
