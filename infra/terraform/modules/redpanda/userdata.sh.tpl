#!/bin/bash
set -euo pipefail

# ── Install Redpanda ─────────────────────────────────────────────────────
curl -1sLf 'https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.rpm.sh' \
  | sudo -E bash
sudo yum install -y redpanda

# ── Configure NVMe ───────────────────────────────────────────────────────
# im4gn instances have local NVMe — mount it
NVME_DEVICE=$(lsblk -dpno NAME,TYPE | awk '$2=="disk" && $1!="/dev/xvda" {print $1; exit}')
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
INSTANCE_ID=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
AZ=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ── Configure Redpanda ───────────────────────────────────────────────────
cat > /etc/redpanda/redpanda.yaml << EOF
redpanda:
  data_directory: /var/lib/redpanda/data
  node_id: null
  rack: "$AZ"

  # Listeners
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

  # Tiered Storage — S3
  cloud_storage_enabled: true
  cloud_storage_bucket: "${tiered_bucket}"
  cloud_storage_region: "${aws_region}"
  cloud_storage_credentials_source: aws_instance_metadata

  # Performance
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

# ── Bootstrap cluster (على أول broker فقط) ──────────────────────────────
sleep 30
if [ "$(hostname)" = "${cluster_name}-redpanda-1" ]; then
  rpk cluster init
fi
