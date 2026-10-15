#!/usr/bin/env bash
set -euo pipefail

REGION=ap-northeast-2
cd "$(dirname "$0")"

install -d -o 65534 -g 65534 /data/prometheus
install -d -o 473 -g 473 /data/alloy
install -d -o 10001 -g 10001 /data/loki
install -d -o 472 -g 0 /data/grafana

monitoring_parameter() {
  aws ssm get-parameter --region "$REGION" --name "/cking/dev/monitoring/$1" \
    --with-decryption --query Parameter.Value --output text
}
GRAFANA_ADMIN_PASSWORD=$(monitoring_parameter GRAFANA_ADMIN_PASSWORD)
GOOGLE_OAUTH_CLIENT_ID=$(monitoring_parameter GOOGLE_OAUTH_CLIENT_ID)
GOOGLE_OAUTH_CLIENT_SECRET=$(monitoring_parameter GOOGLE_OAUTH_CLIENT_SECRET)
GRAFANA_ROLE_ATTRIBUTE_PATH=$(monitoring_parameter GRAFANA_ROLE_ATTRIBUTE_PATH)
export GRAFANA_ADMIN_PASSWORD GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GRAFANA_ROLE_ATTRIBUTE_PATH

# 설정 파일 내용이 바뀌면 라벨 값이 바뀌어 compose가 그 서비스만 다시 만든다
config_hash() {
  find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12
}
PROMETHEUS_CONFIG_HASH=$(config_hash prometheus)
LOKI_CONFIG_HASH=$(config_hash loki)
ALLOY_CONFIG_HASH=$(config_hash alloy)
GRAFANA_CONFIG_HASH=$(config_hash grafana/provisioning)
NGINX_CONFIG_HASH=$(config_hash nginx)
export PROMETHEUS_CONFIG_HASH LOKI_CONFIG_HASH ALLOY_CONFIG_HASH GRAFANA_CONFIG_HASH NGINX_CONFIG_HASH

docker compose pull --quiet
docker compose up -d --remove-orphans
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
