#!/bin/bash
# Shared base provisioning for all golden images:
# apt update/upgrade, common packages, SSH hardening
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== Base: Waiting for cloud-init ==="
/usr/bin/cloud-init status --wait

echo "=== Base: Packages ==="
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl wget jq fail2ban unattended-upgrades

echo "=== Base: SSH Hardening ==="
systemctl enable fail2ban
systemctl enable unattended-upgrades
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
