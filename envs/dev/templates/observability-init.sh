#!/bin/bash
set -euo pipefail

apt-get update
apt-get install -y ca-certificates curl awscli
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

DEVICE=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${data_volume_serial}
for _ in $(seq 1 120); do
  [ -e "$DEVICE" ] && break
  sleep 5
done
[ -e "$DEVICE" ] || { echo "data volume not attached" >&2; exit 1; }

if ! blkid "$DEVICE" > /dev/null 2>&1; then
  mkfs.ext4 -L observability-data "$DEVICE"
fi
mkdir -p /data
UUID=$(blkid -s UUID -o value "$DEVICE")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
