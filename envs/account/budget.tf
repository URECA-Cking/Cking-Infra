# 2개월 상한 50만원은 월 약 $175다. 정상 사용(약 $91)으로는 85%($127.5)가 울리지 않고 NAT Gateway 같은 실수 하나면 울린다.
# 운영을 띄운 동안은 budget_limit_usd를 250으로 올리고 내리면 되돌린다(런북 aws-budget).

variable "budget_limit_usd" {
  description = "월 예산(USD). 평소 150, 운영을 띄운 동안 250"
  type        = number
  default     = 150
}

# 알림 메일은 사람이 Parameter Store에 넣는다(String). 코드·워크플로 로그에 남기지 않는다.
data "aws_ssm_parameter" "budget_email" {
  name = "/cking/account/BUDGET_EMAIL"
}

locals {
  budget_notifications = {
    actual-85      = { type = "ACTUAL", threshold = 85 }
    actual-100     = { type = "ACTUAL", threshold = 100 }
    forecasted-100 = { type = "FORECASTED", threshold = 100 }
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "cking-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.budget_notifications

    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [data.aws_ssm_parameter.budget_email.value]
    }
  }
}
