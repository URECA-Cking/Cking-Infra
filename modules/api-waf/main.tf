# API(ALB) 앞단 WAF. 개발과 운영이 같은 규칙을 쓰도록 모듈로 둔다.
# Core rule set의 본문 8KB 차단은 multipart 업로드와 이벤트 등록·수정을 막으므로, 그 요청만 빼고 직접 막는다.

locals {
  managed_rule_groups = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"]
  body_size_label     = "awswaf:managed:aws:core-rule-set:SizeRestrictions_Body"
  body_size_exempt    = "body-size-exempt"
}

resource "aws_wafv2_ip_set" "allow" {
  count = length(var.allow_ip_cidrs) > 0 ? 1 : 0

  name               = "${var.name}-allow"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allow_ip_cidrs
}

resource "aws_wafv2_web_acl" "this" {
  name  = var.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = aws_wafv2_ip_set.allow

    content {
      name     = "allow-internal"
      priority = 0

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = rule.value.arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.name}-allow-internal"
      }
    }
  }

  dynamic "rule" {
    for_each = var.rate_limit == null ? [] : [var.rate_limit]

    content {
      name     = "rate-limit-per-ip"
      priority = 10

      action {
        dynamic "count" {
          for_each = var.mode == "count" ? [1] : []
          content {}
        }
        dynamic "block" {
          for_each = var.mode == "block" ? [1] : []
          content {}
        }
      }

      statement {
        rate_based_statement {
          limit                 = rule.value
          evaluation_window_sec = var.rate_window_sec
          aggregate_key_type    = "IP"

          scope_down_statement {
            byte_match_statement {
              search_string         = var.api_host
              positional_constraint = "EXACTLY"

              field_to_match {
                single_header {
                  name = "host"
                }
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.name}-rate-limit-per-ip"
      }
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = "AWS-${rule.value}"
      priority = 20 + rule.key

      override_action {
        dynamic "count" {
          for_each = var.mode == "count" ? [1] : []
          content {}
        }
        dynamic "none" {
          for_each = var.mode == "block" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value

          dynamic "rule_action_override" {
            for_each = rule.value == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []

            content {
              name = rule_action_override.value

              action_to_use {
                count {}
              }
            }
          }

          scope_down_statement {
            byte_match_statement {
              search_string         = var.api_host
              positional_constraint = "EXACTLY"

              field_to_match {
                single_header {
                  name = "host"
                }
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${var.name}-AWS-${rule.value}"
      }
    }
  }

  # 규칙 중첩은 3단계까지라, 예외 판정과 차단을 라벨로 나눈다.
  rule {
    name     = "body-size-exempt"
    priority = 30

    action {
      count {}
    }

    rule_label {
      name = local.body_size_exempt
    }

    statement {
      or_statement {
        statement {
          byte_match_statement {
            search_string         = "multipart/form-data"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              single_header {
                name = "content-type"
              }
            }

            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }

        statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"

                field_to_match {
                  method {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              byte_match_statement {
                search_string         = "/api/creator/events"
                positional_constraint = "EXACTLY"

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }

        statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "PATCH"
                positional_constraint = "EXACTLY"

                field_to_match {
                  method {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              byte_match_statement {
                search_string         = "/api/creator/events/"
                positional_constraint = "STARTS_WITH"

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${var.name}-body-size-exempt"
    }
  }

  rule {
    name     = "body-size"
    priority = 31

    action {
      dynamic "count" {
        for_each = var.mode == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.mode == "block" ? [1] : []
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          label_match_statement {
            scope = "LABEL"
            key   = local.body_size_label
          }
        }

        statement {
          not_statement {
            statement {
              label_match_statement {
                scope = "LABEL"
                key   = local.body_size_exempt
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${var.name}-body-size"
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = var.name
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
