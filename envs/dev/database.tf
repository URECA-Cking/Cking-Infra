# 개발 MySQL. 단일 AZ, 프라이빗 서브넷. 마스터 비밀번호는 RDS가 Secrets Manager에서 만들고 교체해 아무도 입력하지 않는다.
# 앱은 마스터가 아닌 앱 전용 계정으로 접속한다. 앱 계정은 RDS가 뜬 뒤 SQL로 만든다(README 개발 환경 절차).
# 서브넷 그룹·파라미터 그룹 이름은 부하 테스트 RDS(envs/loadtest)가 이름으로 같이 쓴다.

resource "aws_db_subnet_group" "main" {
  name        = "dev-cking-db-subnet-group"
  description = "Dev RDS private subnets"
  subnet_ids  = [for k in local.private_subnets : aws_subnet.this[k].id]
}

# 시간대·문자셋은 MySQL 8.4 기본값(UTC, utf8mb4, utf8mb4_0900_ai_ci)이 요구와 같다. 바꿀 때 그룹을 새로 붙이는 재부팅이 없게 미리 연결한다.
resource "aws_db_parameter_group" "main" {
  name        = "dev-cking-mysql84"
  family      = "mysql8.4"
  description = "Dev MySQL 8.4"

  # 운영과 같이 평문 연결을 받지 않는다. 앱·mysql 클라이언트는 기본값(PREFERRED)으로 이미 TLS를 쓴다.
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_157:개발은 단일 AZ다(envs/security/triage.tf accepted-dev, RDS.5)
  #checkov:skip=CKV_AWS_118:Enhanced Monitoring은 로그 과금이라 끄고 부하 테스트 때만 켠다(envs/security/triage.tf accepted-dev, RDS.6)
  #checkov:skip=CKV_AWS_129:로그 내보내기는 필요해질 때 켠다(envs/security/triage.tf accepted-dev, RDS.9)
  #checkov:skip=CKV_AWS_293:개발 비용 구성(envs/security/triage.tf accepted-dev, RDS.8). 지우기는 prevent_destroy로 막는다
  identifier     = "dev-cking-mysql"
  engine         = "mysql"
  engine_version = "8.4.9"
  instance_class = "db.t4g.micro"
  multi_az       = false

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
  availability_zone      = aws_subnet.this["public_2a"].availability_zone
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period    = 7
  backup_window              = "18:00-18:30"
  maintenance_window         = "sun:19:00-sun:19:30"
  copy_tags_to_snapshot      = true
  deletion_protection        = false
  skip_final_snapshot        = false
  final_snapshot_identifier  = "dev-cking-mysql-final"
  auto_minor_version_upgrade = false

  tags = { Name = "dev-cking-mysql" }

  lifecycle {
    prevent_destroy = true
  }
}

# deploy.sh가 읽는 값 중 비밀이 아닌 것. 앱 계정 비밀번호(/cking/dev/DB_PASSWORD)는 사람이 SecureString으로 넣는다.
resource "aws_ssm_parameter" "db" {
  for_each = {
    DB_HOST     = aws_db_instance.main.address
    DB_USERNAME = "cking_app"
  }

  name  = "/cking/dev/${each.key}"
  type  = "String"
  value = each.value
}
