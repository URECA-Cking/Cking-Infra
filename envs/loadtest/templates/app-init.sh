#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# 측정 중에 패키지 업데이트가 돌지 않게 한다.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

apt-get update
apt-get install -y ca-certificates curl jq awscli
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y \
  "docker-ce=${docker_version}" \
  "docker-ce-cli=${docker_version}" \
  "containerd.io=${containerd_version}" \
  "docker-compose-plugin=${compose_version}"

fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

install -d -m 0755 /opt/cking /opt/app-agent

docker --version
docker compose version
aws --version
swapon --show
