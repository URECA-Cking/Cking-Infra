#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

install -d -m 700 /var/lib/app-agent

config_hash() {
  find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12
}
AGENT_CONFIG_HASH=$(config_hash agent.alloy)
export AGENT_CONFIG_HASH

docker compose pull --quiet
docker compose up -d --remove-orphans
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
