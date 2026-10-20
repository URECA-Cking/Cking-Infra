#!/bin/bash
set -euo pipefail

${server_base}

# 수집기는 Redis 지표만 켠다(앱 없음). ElastiCache는 TLS(rediss://)와 감시 전용 사용자로 읽는다.
install -d -m 0755 /opt/app-agent
install -d -m 0700 /var/lib/app-agent-secrets
aws s3 sync --exact-timestamps --region "$REGION" "s3://${observability_bucket}/app-agent/" /opt/app-agent/

(umask 077 && param /cking/prod-monitor/REDIS_PASSWORD > /var/lib/app-agent-secrets/redis-password)
redis_host=$(param /cking/prod-monitor/REDIS_HOST)
redis_user=$(param /cking/prod-monitor/REDIS_USERNAME)

CKING_INSTANCE=prod-cking-monitor \
CKING_APP=0 \
CKING_REDIS_ADDR="rediss://$redis_host:6379" \
CKING_REDIS_USER="$redis_user" \
CKING_REDIS_PASSWORD_FILE=/run/cking/redis-password \
  bash /opt/app-agent/apply.sh
