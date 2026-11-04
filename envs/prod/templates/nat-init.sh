#!/bin/bash
# NAT 인스턴스 첫 부팅: 패킷 전달과 마스커레이드를 부팅마다 다시 거는 서비스를 만든다(재부팅·복구 뒤에도 유지).
set -euo pipefail

cat > /usr/local/sbin/cking-nat.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
sysctl -qw net.ipv4.ip_forward=1
dev=$(ip -4 route show default | awk '{print $5; exit}')
nft delete table ip cking_nat 2>/dev/null || true
nft -f - <<NFT
table ip cking_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname "$dev" ip saddr ${vpc_cidr} masquerade
  }
}
NFT
SCRIPT
chmod 700 /usr/local/sbin/cking-nat.sh

cat > /etc/systemd/system/cking-nat.service <<'UNIT'
[Unit]
Description=Cking NAT forwarding and masquerade
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cking-nat.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now cking-nat.service

# 전달 상태를 1분마다 지표(Cking/NAT ForwardingReady)로 보낸다. 서비스·규칙이 어긋나면 0, 인스턴스가 멈추면 지표가 끊겨 경보가 울린다.
# 첫 부팅 때는 EIP가 아직 붙지 않아 바깥으로 못 나갈 수 있어 설치를 다시 시도한다. 끝내 못 깔면 지표가 없어 경보가 울린다.
for _ in $(seq 1 30); do
  apt-get update -q && apt-get install -y -q awscli && break
  sleep 10
done

cat > /usr/local/sbin/cking-nat-check.sh <<'SCRIPT'
#!/bin/bash
set -uo pipefail
dev=$(ip -4 route show default | awk '{print $5; exit}')
ok=0
if systemctl is-active --quiet cking-nat.service && [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] \
  && [ -n "$dev" ] && nft list table ip cking_nat 2>/dev/null | grep -q "oifname \"$dev\""; then
  ok=1
fi
token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
id=$(curl -sf -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)
aws cloudwatch put-metric-data --region ap-northeast-2 --namespace Cking/NAT --metric-name ForwardingReady \
  --dimensions InstanceId="$id" --value "$ok"
SCRIPT
chmod 700 /usr/local/sbin/cking-nat-check.sh

cat > /etc/systemd/system/cking-nat-check.service <<'UNIT'
[Unit]
Description=Cking NAT forwarding check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cking-nat-check.sh
UNIT

cat > /etc/systemd/system/cking-nat-check.timer <<'UNIT'
[Unit]
Description=Cking NAT forwarding check every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now cking-nat-check.timer
