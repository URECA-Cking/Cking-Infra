#!/bin/bash
set -euo pipefail

${server_base}

# 배포 = 서버 교체. 새 서버는 Parameter Store의 배포 태그로 앱을 띄운 뒤 수집기를 붙인다.
# 수집기는 앱 compose 네트워크(cking_default)에 붙으므로 앱 배포 뒤에 적용한다.
install -d -m 0755 /opt/cking /opt/app-agent

tag=$(param /cking/prod/RELEASE_TAG)
aws s3 cp --region "$REGION" "s3://${deploy_bucket}/releases/$tag/deploy.sh" /opt/cking/deploy.sh
chmod +x /opt/cking/deploy.sh
PARAM_PATH=/cking/prod/ /opt/cking/deploy.sh "$tag"

imds_token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
instance_id=$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id)

aws s3 sync --exact-timestamps --region "$REGION" "s3://${observability_bucket}/app-agent/" /opt/app-agent/
CKING_INSTANCE="prod-cking-app-$instance_id" CKING_REDIS=0 bash /opt/app-agent/apply.sh
