#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

install -d -m 700 /var/lib/app-agent /var/lib/app-agent-secrets

config_hash() {
  find "$@" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12
}

# 서버 지표·로그(agent.alloy)는 항상 켜고, 나머지는 서버 역할에 따라 켠다. 기본값은 개발 앱 서버다.
#   CKING_APP=1      앱 지표(app.alloy). 앱 compose 네트워크에 붙는다. 운영 감시용 서버는 0
#   CKING_REDIS=1    Redis 지표(redis.alloy). 주소 기본값은 같은 네트워크의 redis:6379. 운영 앱 서버는 0
#                    운영 감시용 서버는 CKING_REDIS_ADDR(rediss://…), CKING_REDIS_USER,
#                    CKING_REDIS_PASSWORD_FILE(/var/lib/app-agent-secrets 안 파일의 컨테이너 경로 /run/cking/…)을 넘긴다
#   CKING_CADVISOR=1 컨테이너 지표(cadvisor.alloy). 부하 테스트 서버
#   CKING_JOURNAL=1  systemd 서비스 journald 로그(journal.alloy). 추천 배치 서버
compose_files=(-f compose.yaml)
config_files=(agent.alloy)
if [[ "${CKING_APP:-1}" == "1" ]]; then
  compose_files+=(-f compose.app.yaml)
  config_files+=(app.alloy compose.app.yaml)
fi
if [[ "${CKING_REDIS:-1}" == "1" ]]; then
  export CKING_REDIS_ADDR="${CKING_REDIS_ADDR:-redis:6379}"
  compose_files+=(-f compose.redis.yaml)
  config_files+=(redis.alloy compose.redis.yaml)
fi
if [[ "${CKING_CADVISOR:-0}" == "1" ]]; then
  compose_files+=(-f compose.cadvisor.yaml)
  config_files+=(cadvisor.alloy compose.cadvisor.yaml)
fi
if [[ "${CKING_JOURNAL:-0}" == "1" ]]; then
  compose_files+=(-f compose.journal.yaml)
  config_files+=(journal.alloy compose.journal.yaml)
fi

AGENT_CONFIG_HASH=$(config_hash "${config_files[@]}")
export AGENT_CONFIG_HASH

docker compose "${compose_files[@]}" pull --quiet
docker compose "${compose_files[@]}" up -d --remove-orphans
docker compose "${compose_files[@]}" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
