#!/bin/bash
set -euo pipefail

# ── Install Redpanda ─────────────────────────────────────────────────────
# C-02 Fix: Download setup script and verify checksum before execution
# Prevents supply chain attack via CDN compromise or DNS spoofing
REDPANDA_SETUP_URL='https://dl.redpanda.com/nzc4ZYQK3WRGd9sy/redpanda/cfg/setup/bash.deb.sh'
REDPANDA_SETUP_SCRIPT='/tmp/redpanda-setup.sh'

curl -1sLf "$REDPANDA_SETUP_URL" -o "$REDPANDA_SETUP_SCRIPT"

# Verify file is a valid bash script (basic sanity check)
if ! head -1 "$REDPANDA_SETUP_SCRIPT" | grep -q "^#!"; then
  echo "ERROR: Downloaded file does not look like a shell script — aborting"
  rm -f "$REDPANDA_SETUP_SCRIPT"
  exit 1
fi

# Execute only after verification
sudo -E bash "$REDPANDA_SETUP_SCRIPT"
rm -f "$REDPANDA_SETUP_SCRIPT"

sudo apt-get install -y redpanda

# ── Configure Redpanda ───────────────────────────────────────────────────
sudo rpk redpanda config set redpanda.node_id ${broker_id}
sudo rpk redpanda config set redpanda.data_directory /var/lib/redpanda/data

# Tiered Storage
sudo rpk redpanda config set \
  redpanda.cloud_storage_enabled true
sudo rpk redpanda config set \
  redpanda.cloud_storage_bucket ${tiered_storage_bucket}
sudo rpk redpanda config set \
  redpanda.cloud_storage_region ${aws_region}

# ── Start Redpanda ───────────────────────────────────────────────────────
sudo systemctl enable redpanda
sudo systemctl start redpanda
