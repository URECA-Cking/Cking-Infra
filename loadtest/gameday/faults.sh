#!/bin/bash
# Mac: 게임 데이 장애 주입. 실행기 state.json의 step이 sustain이 되면 시작 시각을 잡고, 그 뒤 정해진 분에 장애를 넣는다.
# 사용법: faults.sh <실행 ID>. 기록은 faults.log(UTC)
set -euo pipefail
R=ap-northeast-2; ID=${1:?실행 ID}; ASG=prod-cking-app
B=loadtest-cking-results-551372961758-ap-northeast-2-an
LOG="$(dirname "$0")/faults.log"
log() { echo "$(date -u +%H:%M:%SZ) $*" | tee -a "$LOG"; }

step() { aws s3 cp --region $R "s3://$B/prod/$ID/state.json" - 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("step") or "", d["status"])' || echo "- starting"; }
# 실행기는 단계 사이에만 state.json을 올려서 k6 단계 중에는 S3에 sustain이 늦게 보인다. 시작 시각(UTC epoch)을 T0로 줄 수 있다
if [ -n "${T0:-}" ]; then log "sustain 시작 $(date -u -r "$T0" +%H:%M:%SZ) (지정)"; else
  until step | grep -q 'sustain'; do sleep 15; done
  T0=$(date +%s); log "sustain 시작 감지"
fi
at() { local m=$1; while [ $(( $(date +%s) - T0 )) -lt $(( m * 60 )) ]; do sleep 5; done; }

# shellcheck disable=SC2016 # JMESPath 백틱은 셸 확장이 아니다
apps() { aws autoscaling describe-auto-scaling-groups --region $R --auto-scaling-group-names $ASG \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].[InstanceId,AvailabilityZone]' --output text; }
ssm_root() {
  local id=$1 cmd=$2 cid
  cid=$(aws ssm send-command --region $R --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[\"$cmd\"]}" --query Command.CommandId --output text)
  for _ in $(seq 1 40); do
    sleep 3
    case $(aws ssm get-command-invocation --region $R --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null) in
      Pending | InProgress | Delayed | "") ;; *) break ;;
    esac
  done
  aws ssm get-command-invocation --region $R --command-id "$cid" --instance-id "$id" --query StandardOutputContent --output text
}

# 1. 앱 서버 1대 강제 종료(그룹이 새로 띄운다)
at 5
victim=$(apps | head -1 | cut -f1)
log "1 앱 서버 종료 $victim"
aws autoscaling terminate-instance-in-auto-scaling-group --region $R --instance-id "$victim" --no-should-decrement-desired-capacity >/dev/null

# 2. RDS 강제 장애 조치(다중 AZ 대기 DB로)
at 15
log "2 RDS 재부팅 + 장애 조치 시작"
aws rds reboot-db-instance --region $R --db-instance-identifier prod-cking-mysql --force-failover >/dev/null
aws rds wait db-instance-available --region $R --db-instance-identifier prod-cking-mysql
log "2 RDS available $(aws rds describe-db-instances --region $R --db-instance-identifier prod-cking-mysql --query 'DBInstances[0].AvailabilityZone' --output text)"

# 3. Valkey 장애 조치(복제본 승격)
at 25
log "3 Valkey test-failover 시작"
aws elasticache test-failover --region $R --replication-group-id prod-cking-redis --node-group-id 0001 >/dev/null
for _ in $(seq 1 90); do
  s=$(aws elasticache describe-replication-groups --region $R --replication-group-id prod-cking-redis --query 'ReplicationGroups[0].Status' --output text)
  [ "$s" = available ] && break; sleep 10
done
# shellcheck disable=SC2016 # JMESPath 백틱은 셸 확장이 아니다
log "3 Valkey $s $(aws elasticache describe-replication-groups --region $R --replication-group-id prod-cking-redis --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[?CurrentRole==`primary`].CacheClusterId' --output text)"

# 4. 앱 메모리 초과: 한 대의 컨테이너 상한을 지금 사용량 아래로 내려 커널 OOM을 일으키고, 죽으면 바로 되돌린다
at 33
victim=$(apps | head -1 | cut -f1)
log "4 앱 메모리 초과 $victim"
ssm_root "$victim" "docker update --memory 700m --memory-swap 700m cking-app >/dev/null; for i in \$(seq 1 60); do [ \$(docker inspect -f {{.State.OOMKilled}} cking-app) = true ] && break; sleep 1; done; docker update --memory 1800m --memory-swap 1800m cking-app >/dev/null; docker inspect -f 'oom={{.State.OOMKilled}} restarts={{.RestartCount}} running={{.State.Running}}' cking-app" | sed 's/^/  /' | tee -a "$LOG"

# 5. 가용 영역 하나의 앱 계층 잃기: app-2a 서브넷에 ALB → 앱 8080을 막는 임시 NACL을 붙였다가 8분 뒤 되돌린다
at 40
SUB=$(aws ec2 describe-subnets --region $R --filters Name=tag:Name,Values=prod-cking-subnet-app-2a --query 'Subnets[0].SubnetId' --output text)
VPC=$(aws ec2 describe-subnets --region $R --subnet-ids "$SUB" --query 'Subnets[0].VpcId' --output text)
ASSOC=$(aws ec2 describe-network-acls --region $R --filters Name=association.subnet-id,Values="$SUB" \
  --query "NetworkAcls[0].Associations[?SubnetId=='$SUB'].NetworkAclAssociationId" --output text)
ORIG=$(aws ec2 describe-network-acls --region $R --filters Name=association.subnet-id,Values="$SUB" --query 'NetworkAcls[0].NetworkAclId' --output text)
NACL=$(aws ec2 create-network-acl --region $R --vpc-id "$VPC" --tag-specifications 'ResourceType=network-acl,Tags=[{Key=Name,Value=gameday-az-2a}]' --query NetworkAcl.NetworkAclId --output text)
n=10; for c in 10.1.0.0/20 10.1.16.0/20; do
  aws ec2 create-network-acl-entry --region $R --network-acl-id "$NACL" --ingress --rule-number $n --protocol tcp --port-range From=8080,To=8080 --cidr-block $c --rule-action deny; n=$((n+1)); done
aws ec2 create-network-acl-entry --region $R --network-acl-id "$NACL" --ingress --rule-number 100 --protocol -1 --cidr-block 0.0.0.0/0 --rule-action allow
aws ec2 create-network-acl-entry --region $R --network-acl-id "$NACL" --egress --rule-number 100 --protocol -1 --cidr-block 0.0.0.0/0 --rule-action allow
NEWASSOC=$(aws ec2 replace-network-acl-association --region $R --association-id "$ASSOC" --network-acl-id "$NACL" --query NewAssociationId --output text)
log "5 app-2a 앱 계층 차단 시작 nacl=$NACL 원래=$ORIG"
at 48
aws ec2 replace-network-acl-association --region $R --association-id "$NEWASSOC" --network-acl-id "$ORIG" >/dev/null
log "5 app-2a 차단 해제"
sleep 30; aws ec2 delete-network-acl --region $R --network-acl-id "$NACL" && log "5 임시 NACL 삭제"
log "끝. 서버: $(apps | tr '\n' ' ')"
