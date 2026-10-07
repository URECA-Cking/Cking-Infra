#!/usr/bin/env bash
set -euo pipefail

REGION=ap-northeast-2
cd "$(dirname "$0")"

install -d -o 65534 -g 65534 /data/prometheus
install -d -o 473 -g 473 /data/alloy
install -d -o 10001 -g 10001 /data/loki
install -d -o 472 -g 0 /data/grafana

GRAFANA_ADMIN_PASSWORD=$(aws ssm get-parameter --region "$REGION" \
  --name /cking/dev/monitoring/GRAFANA_ADMIN_PASSWORD \
  --with-decryption --query Parameter.Value --output text)
export GRAFANA_ADMIN_PASSWORD

docker compose pull --quiet
docker compose up -d --remove-orphans
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
