#!/bin/bash
set -euo pipefail

# ── Install Redpanda ─────────────────────────────────────────────────────
curl -1sLf \
  'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.deb.sh' \
  | sudo -E bash
sudo dnf install -y redpanda

# ── Configure NVMe ───────────────────────────────────────────────────────
NVME_DEVICE=$(lsblk -dpno NAME,TYPE \
  | awk '$2=="disk" && $1!="/dev/xvda" && $1!="/dev/nvme0n1" {print $1; exit}')
if [ -n "$NVME_DEVICE" ]; then
  mkfs.xfs "$NVME_DEVICE"
  mkdir -p /var/lib/redpanda/data
  echo "$NVME_DEVICE /var/lib/redpanda/data xfs defaults,noatime 0 2" >> /etc/fstab
  mount -a
  chown -R redpanda:redpanda /var/lib/redpanda/data
fi

# ── Get instance metadata (IMDSv2) ───────────────────────────────────────
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ── Configure Redpanda ───────────────────────────────────────────────────
cat > /etc/redpanda/redpanda.yaml << EOF
redpanda:
  data_directory: /var/lib/redpanda/data
  node_id: ${broker_id}
  rack: "$AZ"
  kafka_api:
    - address: 0.0.0.0
      port: 9092
  advertised_kafka_api:
    - address: $PRIVATE_IP
      port: 9092
  rpc_server:
    address: 0.0.0.0
    port: 33145
  advertised_rpc_api:
    address: $PRIVATE_IP
    port: 33145
  admin:
    - address: 0.0.0.0
      port: 9644
  cloud_storage_enabled: true
  cloud_storage_bucket: "${tiered_storage_bucket}"
  cloud_storage_region: "${aws_region}"
  cloud_storage_credentials_source: aws_instance_metadata
  developer_mode: false
rpk:
  kafka_api:
    brokers:
      - localhost:9092
pandaproxy:
  pandaproxy_api:
    - address: 0.0.0.0
      port: 8082
schema_registry:
  schema_registry_api:
    - address: 0.0.0.0
      port: 8081
EOF

# ── Start Redpanda ───────────────────────────────────────────────────────
sudo systemctl enable redpanda
sudo systemctl start redpanda

# ── Bootstrap cluster (على broker_id=0 فقط) ─────────────────────────────
if [ "${broker_id}" = "0" ]; then
  sleep 30
  rpk cluster init
fi
