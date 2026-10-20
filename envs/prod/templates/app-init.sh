#!/bin/bash
set -Eeuo pipefail

${server_base}

# 배포 = 서버 교체. 새 서버는 시작 대기(Pending:Wait) 상태로 부팅해 배포 태그로 앱을 띄우고,
# 같은 태그의 스모크 테스트로 자기 자신을 검사한 뒤에야 ALB에 붙는다. 어느 단계든 실패하면 자신을 버린다.
# 대기를 끝내지 못하고 상한(900초)이 지나도 버려진다.
imds_token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
instance_id=$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id)

finish() {
  trap - ERR
  aws autoscaling complete-lifecycle-action --region "$REGION" --auto-scaling-group-name "${asg_name}" \
    --lifecycle-hook-name "${lifecycle_hook}" --instance-id "$instance_id" --lifecycle-action-result "$1" \
    || echo "시작 대기를 끝내지 못했다: $1"
}
trap 'finish ABANDON' ERR

install -d -m 0755 /opt/cking /opt/app-agent

tag=$(param /cking/prod/RELEASE_TAG)
release="s3://${deploy_bucket}/releases/$tag"
aws s3 cp --region "$REGION" "$release/deploy.sh" /opt/cking/deploy.sh
aws s3 cp --region "$REGION" "$release/smoke.js" /opt/cking/smoke.js
chmod +x /opt/cking/deploy.sh
PARAM_PATH=/cking/prod/ /opt/cking/deploy.sh "$tag"

# 수집기는 앱 compose 네트워크(cking_default)에 붙으므로 앱 배포 뒤에 적용한다.
aws s3 sync --exact-timestamps --region "$REGION" "s3://${observability_bucket}/app-agent/" /opt/app-agent/
CKING_INSTANCE="prod-cking-app-$instance_id" CKING_REDIS=0 bash /opt/app-agent/apply.sh

# ALB를 거치지 않고 앱에 직접 붙되, ALB가 붙이는 X-Forwarded-* 헤더를 흉내 내 공개 주소 기준으로 검사한다.
docker run --rm --network host -v /opt/cking/smoke.js:/smoke.js:ro \
  -e BASE_URL=http://localhost:8080 -e PUBLIC_BASE_URL=https://api.cking.co.kr \
  -e FRONTEND_ORIGIN=https://cking.co.kr -e EXPECTED_IMAGE_TAG="$tag" -e DOCS_DISABLED=1 \
  "${k6_image}" run --quiet /smoke.js

finish CONTINUE
