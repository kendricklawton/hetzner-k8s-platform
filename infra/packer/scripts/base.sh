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
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config

# Modern ciphers/kex only — drop legacy algorithms
cat >> /etc/ssh/sshd_config <<'SSHEOF'

# Hardened crypto (CKS-aligned)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSHEOF

systemctl restart ssh || systemctl restart sshd

# Lock sshd to localhost AFTER the restart so Packer's SSH session isn't broken.
# On real nodes, sshd reads this on boot and only listens on 127.0.0.1.
# All remote SSH access goes through Tailscale SSH (--ssh flag in cloud-init).
echo 'ListenAddress 127.0.0.1' >> /etc/ssh/sshd_config
