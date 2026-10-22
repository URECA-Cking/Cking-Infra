#!/bin/bash
set -Eeuo pipefail

${server_base}

# 배포 = 서버 교체. 새 서버는 시작 대기(Pending:Wait) 상태로 부팅해 상태 디스크를 붙이고 배포 버전의 패키지를 설치한 뒤에야
# 서비스에 들어간다. 어느 단계든 실패하거나 대기 상한(900초)이 지나면 버려지고, 그룹이 새 서버를 다시 띄운다.
imds_token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
instance_id=$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id)
az=$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/placement/availability-zone)

finish() {
  trap - ERR
  aws autoscaling complete-lifecycle-action --region "$REGION" --auto-scaling-group-name "${asg_name}" \
    --lifecycle-hook-name "${lifecycle_hook}" --instance-id "$instance_id" --lifecycle-action-result "$1" \
    || echo "시작 대기를 끝내지 못했다: $1"
}
trap 'finish ABANDON' ERR

# 상태 디스크: 옛 서버에서 떨어질 때까지 기다렸다가 이 서버에 붙이고 /var/lib/cking-content에 마운트한다.
volume_id=$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Name,Values=${state_volume}" "Name=availability-zone,Values=$az" \
  --query 'Volumes[0].VolumeId' --output text)
aws ec2 wait volume-available --region "$REGION" --volume-ids "$volume_id"
aws ec2 attach-volume --region "$REGION" --volume-id "$volume_id" --instance-id "$instance_id" --device /dev/sdf >/dev/null
device="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo "$volume_id" | tr -d -)"
for _ in $(seq 1 60); do
  [ -e "$device" ] && break
  sleep 2
done
test -e "$device"
# 처음 붙일 때만 파일 시스템을 만든다.
blkid "$device" >/dev/null || mkfs.ext4 -q -L cking-content "$device"
install -d /var/lib/cking-content
echo "UUID=$(blkid -s UUID -o value "$device") /var/lib/cking-content ext4 defaults,nofail 0 2" >> /etc/fstab
mount /var/lib/cking-content

# 실행 사용자와 배포 패키지. 패키지 안에 Python 3.12와 가상환경이 있어 서버 Python을 쓰지 않는다.
id cking >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin cking
release=$(param ${param_path}RELEASE)
work=$(mktemp -d)
for f in cking-llm.tar.gz cking-llm.tar.gz.sha256; do
  aws s3 cp --region "$REGION" --only-show-errors "s3://${deploy_bucket}/recommendation/releases/$release/$f" "$work/$f"
done
(cd "$work" && sha256sum -c --quiet cking-llm.tar.gz.sha256)
tar -C / -xzf "$work/cking-llm.tar.gz"
rm -rf "$work"
install -m 0644 /opt/cking-llm/deploy/content-worker/*.service /opt/cking-llm/deploy/content-worker/*.timer /etc/systemd/system/
systemctl daemon-reload

# 환경 파일. 값이 모두 있을 때만 타이머를 켠다. 빠진 값이 있으면 서버는 들이고 타이머만 꺼 둔다(값을 넣고 서버를 교체한다).
names=(CKING_BE_URL CKING_CONTENT_TAG_ACCESS_TOKEN CKING_RECOMMENDATION_API_KEY OPENAI_API_KEY DEEPINFRA_API_KEY CKING_TAG_DAILY_CALLS)
paths=()
for name in "$${names[@]}"; do
  paths+=("${param_path}$name")
done
found=$(aws ssm get-parameters --region "$REGION" --names "$${paths[@]}" --with-decryption \
  --query 'Parameters[].[Name,Value]' --output text)
install -d -m 0750 -o root -g cking /etc/cking
env_file=/etc/cking/content-worker.env
(umask 027 && : > "$env_file.tmp")
count=0
while IFS=$'\t' read -r name value; do
  [ -n "$name" ] || continue
  printf '%s=%s\n' "$${name##*/}" "$value" >> "$env_file.tmp"
  count=$((count + 1))
done <<< "$found"
chown root:cking "$env_file.tmp"
mv "$env_file.tmp" "$env_file"
if [ "$count" -eq "$${#names[@]}" ]; then
  systemctl enable --now cking-content-event.timer cking-content-daily.timer
else
  echo "추천 배치 값이 $count/$${#names[@]}개만 있어 타이머를 켜지 않는다"
fi

# 수집기: 서버 지표와 콘텐츠 작업자 journald 로그.
install -d -m 0755 /opt/app-agent
aws s3 sync --exact-timestamps --region "$REGION" "s3://${observability_bucket}/app-agent/" /opt/app-agent/
CKING_INSTANCE="${asg_name}" CKING_APP=0 CKING_REDIS=0 CKING_JOURNAL=1 bash /opt/app-agent/apply.sh

finish CONTINUE
