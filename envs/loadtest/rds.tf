resource "aws_security_group" "db" {
  name        = "${var.env_name}-cking-rds-sg"
  description = "Load test RDS"
  vpc_id      = data.aws_vpc.main.id
  tags        = { Name = "${var.env_name}-cking-rds-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from load test app server"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id
}

# 비밀번호는 Parameter Store에 직접 넣은 값을 읽는다. ephemeral로 읽어 상태 파일에 남기지 않는다.
ephemeral "aws_ssm_parameter" "db_password" {
  arn             = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/${var.env_name}/DB_PASSWORD"
  with_decryption = true
}

# 사양은 개발 RDS(dev-cking-mysql)와 같다. 측정이 끝나면 지우므로 백업·삭제 보호·최종 스냅샷은 끈다.
resource "aws_db_instance" "main" {
  identifier     = "${var.env_name}-cking-mysql"
  engine         = "mysql"
  engine_version = "8.4.9"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name             = "cking"
  username            = "admin"
  password_wo         = ephemeral.aws_ssm_parameter.db_password.value
  password_wo_version = 1

  db_subnet_group_name   = data.aws_db_subnet_group.main.name
  parameter_group_name   = "dev-cking-mysql84"
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = data.aws_subnet.public_2a.availability_zone
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period    = 0
  deletion_protection        = false
  skip_final_snapshot        = true
  apply_immediately          = true
  auto_minor_version_upgrade = false

  tags = { Name = "${var.env_name}-cking-mysql" }
}
