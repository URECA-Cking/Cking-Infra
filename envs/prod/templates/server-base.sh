# shellcheck shell=bash
# 운영 서버 공통 준비: Docker(개발 앱 서버와 같은 버전), AWS CLI, swap. 각 서버의 첫 부팅 스크립트 앞에 붙는다.
export DEBIAN_FRONTEND=noninteractive

# 패키지 자동 업데이트가 서버마다 다른 시점에 돌지 않게 한다. 갱신은 AMI·버전을 바꿔 서버를 교체한다.
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

REGION=ap-northeast-2
param() {
  aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption --query Parameter.Value --output text
}
