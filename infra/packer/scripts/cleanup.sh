#!/bin/bash
# Shared cleanup for all golden images — run as the final provisioner
set -euo pipefail

echo "=== Cleanup ==="
apt-get purge -y trivy 2>/dev/null || true
rm -f /etc/apt/sources.list.d/trivy.list
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --seed
truncate -s 0 /etc/machine-id /var/lib/dbus/machine-id /etc/hostname
