#!/bin/bash
set -euo pipefail
trap 'echo "[FATAL] cleanup.sh error on line $LINENO — exit code $?"' ERR

echo "=== Cleanup ==="
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/netplan/50-cloud-init.yaml
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --seed
truncate -s 0 /etc/machine-id /var/lib/dbus/machine-id /etc/hostname
echo "[Cleanup] Done"
