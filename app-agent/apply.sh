#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

install -d -m 700 /var/lib/app-agent

config_hash() {
  find "$@" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12
}

# CKING_CADVISOR=1이면 컨테이너 지표를 켠다(부하 테스트 서버).
compose_files=(-f compose.yaml)
config_files=(agent.alloy)
if [[ "${CKING_CADVISOR:-0}" == "1" ]]; then
  compose_files+=(-f compose.cadvisor.yaml)
  config_files+=(cadvisor.alloy compose.cadvisor.yaml)
fi

AGENT_CONFIG_HASH=$(config_hash "${config_files[@]}")
export AGENT_CONFIG_HASH

docker compose "${compose_files[@]}" pull --quiet
docker compose "${compose_files[@]}" up -d --remove-orphans
docker compose "${compose_files[@]}" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
