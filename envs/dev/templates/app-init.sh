#!/bin/bash
set -euo pipefail

${server_base}

# 앱은 BE CI가 SSM Run Command로 /opt/cking/deploy.sh를 받아 띄우고, 수집기는 Infra CI(deploy-app-agent.yml)가 /opt/app-agent에 둔다.
install -d -m 0755 /opt/cking /opt/app-agent
