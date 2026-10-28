#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# 측정 중에 패키지 업데이트가 돌지 않게 한다.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

apt-get update
apt-get install -y ca-certificates curl unzip

cd /tmp

curl -fsSLO "https://awscli.amazonaws.com/awscli-exe-linux-aarch64-${awscli_version}.zip"
echo "${awscli_sha256}  awscli-exe-linux-aarch64-${awscli_version}.zip" | sha256sum -c -
unzip -q -o "awscli-exe-linux-aarch64-${awscli_version}.zip"
./aws/install --update

curl -fsSLO "https://github.com/grafana/k6/releases/download/${k6_version}/k6-${k6_version}-linux-arm64.tar.gz"
echo "${k6_sha256}  k6-${k6_version}-linux-arm64.tar.gz" | sha256sum -c -
tar -xzf "k6-${k6_version}-linux-arm64.tar.gz"
install -m 0755 "k6-${k6_version}-linux-arm64/k6" /usr/local/bin/k6

curl -fsSLO "https://github.com/grafana/alloy/releases/download/${alloy_version}/alloy-linux-arm64.zip"
echo "${alloy_sha256}  alloy-linux-arm64.zip" | sha256sum -c -
unzip -o alloy-linux-arm64.zip
install -m 0755 alloy-linux-arm64 /usr/local/bin/alloy

# 많은 연결을 여는 쪽이라 임시 포트 범위와 파일 수 한도를 넓힌다.
cat > /etc/sysctl.d/90-k6.conf <<'EOF'
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl --system
cat > /etc/security/limits.d/90-k6.conf <<'EOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

# k6 서버의 CPU·메모리를 관측 서버로 보낸다. k6 자체 지표는 k6가 직접 보낸다.
install -d -m 0755 /etc/alloy /var/lib/alloy
cat > /etc/alloy/k6.alloy <<'EOF'
prometheus.exporter.unix "host" {}

discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets

  rule {
    target_label = "instance"
    replacement  = "${instance}"
  }

  rule {
    target_label = "job"
    replacement  = "node"
  }
}

prometheus.scrape "host" {
  targets         = discovery.relabel.host.output
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.gateway.receiver]
}

prometheus.remote_write "gateway" {
  endpoint {
    url = "http://${gateway_ip}:9009/api/v1/metrics/write"
  }
}
EOF

cat > /etc/systemd/system/alloy.service <<'EOF'
[Unit]
Description=Grafana Alloy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/alloy run /etc/alloy/k6.alloy --storage.path=/var/lib/alloy --disable-reporting
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# k6 실행 때 결과 지표를 관측 서버로 보내는 주소. 실행: k6 run -o experimental-prometheus-rw <스크립트>
cat > /etc/profile.d/k6.sh <<'EOF'
export K6_PROMETHEUS_RW_SERVER_URL="http://${gateway_ip}:9009/api/v1/metrics/write"
EOF

systemctl daemon-reload
systemctl enable --now alloy

k6 version
aws --version
systemctl is-active alloy
