# Security Hub에서 받아들이기로 한 지적을 억제한다(이유는 Infra #219 본문 "받아들인 것"). 남는 "새 지적"은 실제로 볼 것만.
# 리소스를 가리지 않는 검사는 검사 번호로, 특정 리소스만 받아들인 검사는 이름·이름표로 좁힌다. 새로 생긴 리소스는 다시 판단한다.

locals {
  securityhub_suppress = {
    "accepted-network" = {
      order    = 10
      note     = "인터페이스 엔드포인트(AZ당 월 약 $7.3)는 NAT 경유로 대신, 대상 그룹 HTTP는 ALB에서 TLS 종료·앱은 프라이빗, VPC 퍼블릭 차단은 인터넷 경로가 필요 (Infra #219)"
      controls = ["EC2.10", "EC2.55", "EC2.56", "EC2.57", "EC2.58", "EC2.60", "EC2.172", "ELB.21", "ELB.22"]
    }
    "accepted-logging" = {
      order    = 20
      note     = "CloudTrail은 SSE-S3·S3 보관으로 충분, 런타임 모니터링은 ECS·EKS 없음, Macie·서버 접근 로그는 비용 대비 CloudTrail로 대신 (Infra #219)"
      controls = ["CloudTrail.2", "CloudTrail.5", "GuardDuty.7", "GuardDuty.11", "GuardDuty.12", "GuardDuty.13", "Macie.1", "S3.9"]
    }
    "accepted-identity-data" = {
      order    = 30
      note     = "앱 계정은 비밀번호·마스터는 Secrets Manager 자동 교체, 기본 포트·관리자 이름 유지, 경보 진단 기록은 만료 시각이 있는 임시 표, 관리자 1명·Identity Center 불가 (Infra #219)"
      controls = ["RDS.10", "RDS.23", "RDS.25", "DynamoDB.2", "DynamoDB.6", "IAM.2"]
    }
  }
}

resource "aws_securityhub_automation_rule" "suppress" {
  for_each = local.securityhub_suppress

  rule_name   = each.key
  description = each.value.note
  rule_order  = each.value.order

  criteria {
    dynamic "compliance_security_control_id" {
      for_each = each.value.controls
      content {
        comparison = "EQUALS"
        value      = compliance_security_control_id.value
      }
    }
    compliance_status {
      comparison = "EQUALS"
      value      = "FAILED"
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      note {
        text       = each.value.note
        updated_by = "envs/security"
      }
      workflow {
        status = "SUPPRESSED"
      }
    }
  }

  depends_on = [aws_securityhub_account.this]
}

# 개발 환경: 비용 구성(단일 AZ RDS, ALB 접근 로그·삭제 보호 없음, 버킷 수명 주기, 승인 버튼 공개 함수 URL은 Slack 서명 검사)
resource "aws_securityhub_automation_rule" "suppress_dev" {
  rule_name   = "accepted-dev"
  description = "개발 환경 비용 구성. 승인 버튼 함수 URL은 Slack 서명을 검사한다 (Infra #219)"
  rule_order  = 40

  criteria {
    dynamic "compliance_security_control_id" {
      for_each = ["RDS.5", "RDS.6", "RDS.8", "RDS.9", "ELB.4", "ELB.5", "ELB.6", "S3.13", "Lambda.1", "AutoScaling.2"]
      content {
        comparison = "EQUALS"
        value      = compliance_security_control_id.value
      }
    }
    dynamic "resource_id" {
      for_each = ["dev-cking-", "loadtest-cking-"]
      content {
        comparison = "CONTAINS"
        value      = resource_id.value
      }
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      note {
        text       = "개발 환경 비용 구성 (Infra #219)"
        updated_by = "envs/security"
      }
      workflow {
        status = "SUPPRESSED"
      }
    }
  }

  depends_on = [aws_securityhub_account.this]
}

# 공인 IP가 필요한 서버: NAT 인스턴스, 개발 서버(퍼블릭 서브넷 구성), 부하 테스트 서버(측정 뒤 삭제)
resource "aws_securityhub_automation_rule" "suppress_public_instances" {
  rule_name   = "accepted-public-instances"
  description = "NAT 인스턴스는 공인 IP가 필요하고, 개발·부하 테스트 서버는 비용 때문에 퍼블릭 서브넷 (Infra #219)"
  rule_order  = 50

  criteria {
    compliance_security_control_id {
      comparison = "EQUALS"
      value      = "EC2.9"
    }
    dynamic "resource_tags" {
      for_each = ["prod-cking-nat-", "dev-cking-", "loadtest-cking-"]
      content {
        comparison = "CONTAINS"
        key        = "Name"
        value      = resource_tags.value
      }
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      note {
        text       = "공인 IP가 필요한 서버 (Infra #219)"
        updated_by = "envs/security"
      }
      workflow {
        status = "SUPPRESSED"
      }
    }
  }

  depends_on = [aws_securityhub_account.this]
}

# 운영에서 받아들인 것: 추천 배치 그룹은 상태 디스크가 2a에 묶임, 운영 RDS 마이너 업그레이드는 사람이 시점을 정함, 로그 내보내기는 느린 쿼리만
resource "aws_securityhub_automation_rule" "suppress_prod" {
  rule_name   = "accepted-prod"
  description = "추천 배치 단일 AZ(상태 디스크), 운영 RDS 마이너 업그레이드 수동, 느린 쿼리 로그만 내보냄 (Infra #219)"
  rule_order  = 60

  criteria {
    dynamic "compliance_security_control_id" {
      for_each = ["AutoScaling.2", "RDS.13", "RDS.9"]
      content {
        comparison = "EQUALS"
        value      = compliance_security_control_id.value
      }
    }
    dynamic "resource_id" {
      for_each = ["autoScalingGroupName/prod-cking-recommendation", ":db:prod-cking-mysql"]
      content {
        comparison = "CONTAINS"
        value      = resource_id.value
      }
    }
  }

  actions {
    type = "FINDING_FIELDS_UPDATE"
    finding_fields_update {
      note {
        text       = "운영에서 받아들인 구성 (Infra #219)"
        updated_by = "envs/security"
      }
      workflow {
        status = "SUPPRESSED"
      }
    }
  }

  depends_on = [aws_securityhub_account.this]
}
