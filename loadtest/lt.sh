#!/bin/bash
# 부하 테스트 환경 생애 주기. Mac(또는 CI)에서 저장소 루트 기준으로 실행한다. 시나리오 실행은 k6 서버의 ltrun.py가 한다.
# 사용법:
#   lt.sh up                          envs/loadtest plan → apply
#   lt.sh prepare [이미지 태그]          앱 배포(기본: 개발 앱 서버에 떠 있는 태그)·수집기
#   lt.sh start <시나리오 파일> [대상]     k6 서버에서 실행기를 띄우고 실행 ID를 출력(대상 기본 loadtest)
#   lt.sh status <실행 ID> [대상]        진행 상태와 최근 기록
#   lt.sh wait <실행 ID> [대상]          끝날 때까지 기다린 뒤 결과를 받는다
#   lt.sh fetch <실행 ID> [대상]         결과를 ./loadtest-runs/<ID>/로 받는다(LT_OUT으로 바꿈, 저장소에 넣지 않는다)
#   lt.sh down                        envs/loadtest destroy
#   lt.sh all <시나리오 파일> [이미지 태그]  up → prepare → start → wait → down. 실패·중단해도 down
# 실행기 코드는 이 저장소의 HEAD 커밋을 k6 서버가 GitHub에서 받는다. HEAD가 원격에 올라가 있어야 한다.
set -euo pipefail

R=ap-northeast-2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TF="$ROOT/envs/loadtest"
BUCKET=loadtest-cking-results-551372961758-ap-northeast-2-an
DEPLOY_BUCKET=dev-cking-deploy-551372961758
OBS_BUCKET=dev-cking-observability-551372961758-ap-northeast-2-an
OUT="${LT_OUT:-$ROOT/loadtest-runs}"

log() { echo "$(date -u +%H:%M:%SZ) $*" >&2; }

instance() {
  aws ec2 describe-instances --region $R --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

k6_name() { [ "${1:-loadtest}" = prod ] && echo prod-cking-k6 || echo loadtest-cking-k6; }

# ssm <인스턴스 ID> <제한 초> <bash 스크립트>: root로 실행하고 표준 출력을 보여 준다. 실패하면 표준 오류와 함께 종료 코드 1
ssm() {
  local id=$1 limit=$2 script=$3 params cid s
  params=$(mktemp)
  python3 -I - "$script" "$limit" > "$params" <<'PYEOF'
import json, sys
script, limit = sys.argv[1], sys.argv[2]
print(json.dumps({"commands": ["bash -euo pipefail <<'LTEOF'", *script.splitlines(), "LTEOF"], "executionTimeout": [limit]}))
PYEOF
  cid=$(aws ssm send-command --region $R --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "file://$params" --query Command.CommandId --output text)
  rm -f "$params"
  while :; do
    sleep 3
    s=$(aws ssm get-command-invocation --region $R --instance-id "$id" --command-id "$cid" --query Status --output text 2>/dev/null || true)
    case "$s" in Pending | InProgress | Delayed | "") ;; *) break ;; esac
  done
  aws ssm get-command-invocation --region $R --instance-id "$id" --command-id "$cid" --query StandardOutputContent --output text
  if [ "$s" != Success ]; then
    log "SSM $s ($id)"
    aws ssm get-command-invocation --region $R --instance-id "$id" --command-id "$cid" --query StandardErrorContent --output text >&2
    return 1
  fi
}

# 서버가 SSM에 붙고 첫 부팅 스크립트가 끝날 때까지 기다린다.
ready() {
  local id=$1 _
  for _ in $(seq 1 60); do
    [ "$(aws ssm describe-instance-information --region $R --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = Online ] && break
    sleep 10
  done
  ssm "$id" 1200 "cloud-init status --wait >/dev/null || true; cloud-init status" >&2
}

cmd_up() {
  terraform -chdir="$TF" init -input=false >/dev/null
  terraform -chdir="$TF" plan -input=false -out=tfplan | grep -E '^(Plan|No changes)|will be (created|destroyed|updated)|must be replaced'
  terraform -chdir="$TF" apply -input=false tfplan
}

cmd_prepare() {
  local tag=${1:-} app k6
  if [ -z "$tag" ]; then
    tag=$(ssm "$(instance dev-cking-app)" 60 "docker inspect -f '{{.Config.Image}}' cking-app" | head -1)
    tag=${tag##*:}
  fi
  app=$(instance loadtest-cking-app); k6=$(instance loadtest-cking-k6)
  if [ -z "$app" ] || [ -z "$k6" ]; then
    log "앱 또는 k6 서버가 없음. lt.sh up 먼저"
    exit 1
  fi
  log "서버 준비 대기 app=$app k6=$k6"
  ready "$app"; ready "$k6"
  log "앱 배포 $tag"
  ssm "$app" 900 "aws s3 cp --region $R s3://$DEPLOY_BUCKET/releases/$tag/deploy.sh /opt/cking/deploy.sh --only-show-errors
chmod 700 /opt/cking/deploy.sh
PARAM_PATH=/cking/loadtest/ /opt/cking/deploy.sh $tag 2>&1 | tail -3" >&2
  log "수집기"
  ssm "$app" 600 "aws s3 sync --region $R --exact-timestamps --only-show-errors s3://$OBS_BUCKET/app-agent/ /opt/app-agent/
CKING_INSTANCE=loadtest-cking-app CKING_CADVISOR=1 bash /opt/app-agent/apply.sh 2>&1 | tail -3" >&2
  echo "$tag"
}

cmd_start() {
  local file=${1:?시나리오 파일} target=${2:-loadtest} k6 infra be tag id b64
  python3 "$ROOT/loadtest/runner/ltrun.py" check "$file"
  infra=$(git -C "$ROOT" rev-parse HEAD)
  git -C "$ROOT" branch -r --contains "$infra" | grep -q . || { log "HEAD $infra가 원격에 없음. 푸시 먼저"; exit 1; }
  k6=$(instance "$(k6_name "$target")")
  [ -n "$k6" ] || { log "k6 서버 없음"; exit 1; }
  if [ "$target" = prod ]; then
    tag=$(aws ssm get-parameter --region $R --name /cking/prod/RELEASE_TAG --query Parameter.Value --output text)
  else
    tag=$(ssm "$(instance loadtest-cking-app)" 60 "docker inspect -f '{{.Config.Image}}' cking-app" | head -1)
    tag=${tag##*:}
  fi
  be=${tag##*-}
  id="$(date -u +%Y%m%d-%H%M%S)-$(basename "$file" .toml)"
  b64=$(base64 < "$file" | tr -d '\n')
  log "실행 $id: 대상 $target, Infra $infra, BE $be(이미지 $tag)"
  ssm "$k6" 300 "rm -rf /opt/loadtest/infra.new && mkdir -p /opt/loadtest/infra.new /opt/loadtest/runs/$id
curl -fsSL https://codeload.github.com/URECA-Cking/Cking-Infra/tar.gz/$infra | tar -xz --strip-components=1 -C /opt/loadtest/infra.new
rm -rf /opt/loadtest/infra && mv /opt/loadtest/infra.new /opt/loadtest/infra
echo $b64 | base64 -d > /opt/loadtest/runs/$id/scenario.toml
systemd-run --unit ltrun-$id --collect python3 /opt/loadtest/infra/loadtest/runner/ltrun.py run --target $target \
  --scenario /opt/loadtest/runs/$id/scenario.toml --run-id $id --infra-commit $infra --be-commit $be" >&2
  echo "$id"
}

state() { aws s3 cp --region $R "s3://$BUCKET/${2:-loadtest}/$1/state.json" - 2>/dev/null; }

cmd_status() {
  local id=${1:?실행 ID} target=${2:-loadtest}
  state "$id" "$target" || echo "state.json 아직 없음"
  ssm "$(instance "$(k6_name "$target")")" 60 "tail -n 15 /opt/loadtest/runs/$id/timeline.log" || true
}

cmd_fetch() {
  local id=${1:?실행 ID} target=${2:-loadtest}
  aws s3 sync --region $R --only-show-errors "s3://$BUCKET/$target/$id/" "$OUT/$id/"
  log "결과: $OUT/$id/results.md"
}

cmd_wait() {
  local id=${1:?실행 ID} target=${2:-loadtest} s
  while :; do
    s=$(state "$id" "$target" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d.get("step") or "")' 2>/dev/null || echo "starting")
    case "$s" in done* | failed* | stopped*) break ;; esac
    log "$id $s"
    sleep 60
  done
  log "$id $s"
  cmd_fetch "$id" "$target"
  [[ "$s" == done* ]]
}

cmd_down() {
  terraform -chdir="$TF" init -input=false >/dev/null
  terraform -chdir="$TF" destroy -input=false -auto-approve | tail -1
}

# 명령 치환 안에서는 -e가 꺼져(macOS bash 3.2는 inherit_errexit도 없다) 실패해도 다음 단계로 넘어간다.
# 그래서 결과를 파일로 받고 함수는 그대로 실행한다.
cmd_all() {
  local file=${1:?시나리오 파일} tag=${2:-} id rc=0 out
  out=$(mktemp)
  trap 'log "환경 삭제"; cmd_down; rm -f "$out"' EXIT
  cmd_up
  cmd_prepare "$tag" > "$out"
  tag=$(tail -n 1 "$out")
  cmd_start "$file" > "$out"
  id=$(tail -n 1 "$out")
  cmd_wait "$id" || rc=$?
  return $rc
}

c=${1:-}; shift || true
case "$c" in
  up | prepare | start | status | wait | fetch | down | all) "cmd_$c" "$@" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
