# MySQL 다중 AZ(주 + 대기 1). 마스터 비밀번호는 RDS가 Secrets Manager에서 만들고 교체해 아무도 입력하지 않는다.
# 앱은 마스터가 아닌 앱 전용 계정으로 접속한다. 앱 계정은 RDS가 뜬 뒤 SQL로 만든다(README 운영 환경 절차).

resource "aws_db_subnet_group" "main" {
  name       = "prod-cking-db"
  subnet_ids = [aws_subnet.this["data-2a"].id, aws_subnet.this["data-2b"].id]
}

# 쿼리 하나가 1초를 넘으면 API p95 1초 기준을 혼자 넘기므로 그 이상을 남긴다.
resource "aws_db_parameter_group" "main" {
  name   = "prod-cking-mysql84"
  family = "mysql8.4"

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "1"
  }

  parameter {
    name  = "log_output"
    value = "FILE"
  }
}

# RDS가 만들기 전에 로그 그룹을 먼저 두어 보존 기간을 정한다.
resource "aws_cloudwatch_log_group" "slow_query" {
  name              = "/aws/rds/instance/prod-cking-mysql/slowquery"
  retention_in_days = 14
}

# 평소 60초. 운영 부하 테스트 동안 1초로 apply해 정각의 CPU steal과 RDS 관리 프로세스를 보고, 끝나면 되돌린다.
# 1초는 RDSOSMetrics 수집이 시간당 약 28MB(2026-10-21 부하 테스트 RDS 측정)라 켜 두면 월 약 $16이다.
variable "rds_monitoring_interval" {
  description = "RDS Enhanced Monitoring 간격(초)"
  type        = number
  default     = 60

  validation {
    condition     = contains([1, 5, 10, 15, 30, 60], var.rds_monitoring_interval)
    error_message = "Enhanced Monitoring 간격은 1, 5, 10, 15, 30, 60 중 하나다."
  }
}

resource "aws_db_instance" "main" {
  identifier     = "prod-cking-mysql"
  engine         = "mysql"
  engine_version = "8.4.9"
  instance_class = "db.t4g.small"
  multi_az       = true

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "cking"
  username                    = "admin"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  enabled_cloudwatch_logs_exports = ["slowquery"]

  monitoring_interval = var.rds_monitoring_interval
  monitoring_role_arn = "arn:aws:iam::551372961758:role/prod-cking-rds-monitoring-role"

  # 다중 AZ 백업은 대기 인스턴스에서 떠서 주 인스턴스 I/O에 영향이 없다. 시각은 개발과 같은 새벽(KST)에 둔다.
  backup_retention_period    = 14
  backup_window              = "18:00-18:30"
  maintenance_window         = "sun:19:00-sun:19:30"
  copy_tags_to_snapshot      = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "prod-cking-mysql-final"
  auto_minor_version_upgrade = false

  tags = { Name = "prod-cking-mysql" }

  depends_on = [aws_cloudwatch_log_group.slow_query]
}
