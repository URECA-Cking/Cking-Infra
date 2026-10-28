#!/bin/bash
# 앱 서버(root)에서 실행기(ltrun.py)가 SSM으로 부르는 데이터 작업. 비밀값은 Parameter Store에서 읽어 환경변수로만 넘긴다.
# 사용법: lt-app.sh <경로 /cking/loadtest|/cking/prod> <명령> [인자...]
#   sql "<SQL>"                 조회(UTC, 머리글 없음, 탭 구분)
#   seed "<SET 문>"             seed.sql
#   seed-closing <크리에이터> <분>  seed-closing.sql
#   redis <명령...>              Redis(부하 테스트: 앱 서버 컨테이너, 운영: ElastiCache TLS·앱 사용자)
#   stop-app                    앱 컨테이너 정지
#   wipe                        Redis·DB 비우기. 앱이 멈춘 상태에서만
#   deploy                      지금 이미지 태그로 deploy.sh(/readyz UP까지)
#   fresh                       회원·관리자·크리에이터·이벤트 수(새 DB면 1 1 0 0)
#   verify [이벤트 ID]           BE verify.sh
set -euo pipefail

P="${1:?경로}"; CMD="${2:?명령}"; shift 2
R=ap-northeast-2
BE=/opt/loadtest/be/loadtest
MYSQL_IMAGE=mysql:8.4
VALKEY_IMAGE=valkey/valkey:7.2

case "$P" in
  /cking/loadtest | /cking/prod) ;;
  *) echo "경로는 /cking/loadtest 또는 /cking/prod: $P" >&2; exit 2 ;;
esac

param() { aws ssm get-parameter --region "$R" --name "$P/$1" --with-decryption --query Parameter.Value --output text; }

db_env() {
  DB_HOST=$(param DB_HOST); DB_USER=$(param DB_USERNAME); MYSQL_PWD=$(param DB_PASSWORD); export MYSQL_PWD
}

mysql_run() {
  docker run --rm -i -e MYSQL_PWD --network host -v "$BE:/lt:ro" "$MYSQL_IMAGE" \
    mysql -h "$DB_HOST" -u "$DB_USER" -N -B "$@"
}

redis_env() {
  if [ "$P" = /cking/prod ]; then
    REDIS_HOST=$(param REDIS_HOST); REDIS_USER=$(param REDIS_USERNAME); REDISCLI_AUTH=$(param REDIS_PASSWORD); export REDISCLI_AUTH
  fi
}

redis_run() {
  if [ "$P" = /cking/prod ]; then
    docker run --rm -i -e REDISCLI_AUTH -v /etc/ssl/certs/ca-certificates.crt:/ca.crt:ro "$VALKEY_IMAGE" \
      valkey-cli --tls --cacert /ca.crt -h "$REDIS_HOST" --user "$REDIS_USER" "$@"
  else
    docker exec -i cking-redis redis-cli "$@"
  fi
}

app_running() { [ "$(docker inspect -f '{{.State.Running}}' cking-app 2>/dev/null)" = true ]; }

case "$CMD" in
  sql)
    db_env; mysql_run cking -e "SET time_zone = '+00:00'; $1" ;;
  seed)
    db_env; mysql_run cking -e "$1; source /lt/seed.sql;" ;;
  seed-closing)
    db_env; mysql_run cking -e "SET @closing_creator = $1, @closing_minutes = $2; source /lt/seed-closing.sql;" ;;
  redis)
    redis_env; redis_run "$@" ;;
  stop-app)
    docker stop cking-app >/dev/null
    ! app_running && echo stopped ;;
  wipe)
    # 앱이 돌면 일정 작업이 남은 DB로 Redis Gate·집계를 다시 채운다(BE docs/operations/loadtest.md "운영 데이터 되돌리기")
    if app_running; then echo "앱이 돌고 있어 비우지 않음" >&2; exit 1; fi
    db_env; redis_env
    # valkey-cli·redis-cli는 NOAUTH·NOPERM에도 종료 코드 0이라 응답을 직접 본다
    out=$(redis_run FLUSHALL); [ "$out" = OK ] || { echo "Redis 초기화 실패: $out" >&2; exit 1; }
    out=$(redis_run DBSIZE); [ "$out" = 0 ] || { echo "Redis에 키가 남음: $out" >&2; exit 1; }
    mysql_run -e "DROP DATABASE IF EXISTS cking; CREATE DATABASE cking;"
    echo "초기화 완료" ;;
  deploy)
    if [ "$P" = /cking/prod ]; then
      tag=$(aws ssm get-parameter --region "$R" --name /cking/prod/RELEASE_TAG --query Parameter.Value --output text)
    else
      image=$(docker inspect -f '{{.Config.Image}}' cking-app); tag=${image##*:}
    fi
    PARAM_PATH="$P/" /opt/cking/deploy.sh "$tag" 2>&1 | tail -3
    echo "tag=$tag" ;;
  fresh)
    db_env
    mysql_run cking -e "SELECT (SELECT COUNT(*) FROM member), (SELECT COUNT(*) FROM admin_account), (SELECT COUNT(*) FROM creator), (SELECT COUNT(*) FROM event)" ;;
  verify)
    cd "$BE"; PARAM_PATH="$P" bash verify.sh "$@" ;;
  *)
    echo "알 수 없는 명령: $CMD" >&2; exit 2 ;;
esac
