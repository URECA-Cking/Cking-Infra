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
