# Valkey 7.2(개발 Redis 7.2와 같은 계열). 응모 Lua가 해시 태그 없는 여러 키를 한 번에 써서 클러스터 모드는 끈다.
# 주 2a + 복제 2b, 자동 장애 조치. 잔액 키가 지워지면 안 되므로 noeviction.
# 인증은 사용자 그룹: 앱 사용자(전체)와 감시 사용자(읽기 명령만). 비밀번호는 Parameter Store에 직접 넣은 값을 ephemeral로 읽어 상태 파일에 남기지 않는다.

locals {
  # BE #673 수정 뒤 다시 잰 메모리로 확정한다.
  redis_node_type = "cache.t4g.small"
}

ephemeral "aws_ssm_parameter" "redis_app_password" {
  arn             = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/prod/REDIS_PASSWORD"
  with_decryption = true
}

ephemeral "aws_ssm_parameter" "redis_monitor_password" {
  arn             = "arn:aws:ssm:ap-northeast-2:551372961758:parameter/cking/prod-monitor/REDIS_PASSWORD"
  with_decryption = true
}

resource "aws_elasticache_user" "app" {
  user_id              = "cking-app"
  user_name            = "cking-app"
  engine               = "valkey"
  access_string        = "on ~* &* +@all"
  passwords_wo         = ephemeral.aws_ssm_parameter.redis_app_password.value
  passwords_wo_version = 1
}

# redis_exporter 권장 권한에서 ElastiCache가 막는 CONFIG와 쓰지 않는 EVAL·CLUSTER를 뺐다.
resource "aws_elasticache_user" "monitor" {
  user_id              = "cking-monitor"
  user_name            = "cking-monitor"
  engine               = "valkey"
  access_string        = "on ~* &* -@all +@connection +info +xinfo +xlen +slowlog +latency +memory +type +strlen +llen +scard +zcard +hlen +pfcount +get +scan +command|info"
  passwords_wo         = ephemeral.aws_ssm_parameter.redis_monitor_password.value
  passwords_wo_version = 1
}

resource "aws_elasticache_user_group" "main" {
  user_group_id = "prod-cking"
  engine        = "valkey"
  user_ids      = [aws_elasticache_user.app.user_id, aws_elasticache_user.monitor.user_id]
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "prod-cking-redis"
  subnet_ids = [aws_subnet.this["data-2a"].id, aws_subnet.this["data-2b"].id]
}

resource "aws_elasticache_parameter_group" "main" {
  name   = "prod-cking-valkey7"
  family = "valkey7"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "prod-cking-redis"
  description          = "Prod Valkey"
  engine               = "valkey"
  engine_version       = "7.2"
  node_type            = local.redis_node_type
  num_cache_clusters   = 2
  port                 = 6379

  automatic_failover_enabled  = true
  multi_az_enabled            = true
  preferred_cache_cluster_azs = ["ap-northeast-2a", "ap-northeast-2b"]

  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
  parameter_group_name = aws_elasticache_parameter_group.main.name

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.main.user_group_id]

  snapshot_retention_limit = 7
  snapshot_window          = "18:00-19:00"
  maintenance_window       = "sun:20:00-sun:21:00"

  tags = { Name = "prod-cking-redis" }
}
