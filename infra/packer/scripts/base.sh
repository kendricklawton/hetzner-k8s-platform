#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
trap 'echo "[FATAL] base.sh error on line $LINENO — exit code $?"' ERR

echo "=== Base: Waiting for cloud-init ==="
# cloud-init exits code 2 on Ubuntu 24.04 Noble even on success (canonical/cloud-init#5971)
/usr/bin/cloud-init status --wait || true
echo "[Base] cloud-init status: $(cloud-init status 2>/dev/null || echo 'unknown')"

echo "=== Base: Packages ==="
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl wget jq fail2ban unattended-upgrades
echo "[Base] Packages installed OK"

echo "=== Base: SSH Hardening ==="
systemctl enable fail2ban
systemctl enable unattended-upgrades
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config <<'SSHEOF'

# Hardened crypto (CKS-aligned)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
SSHEOF

systemctl restart ssh || systemctl restart sshd
echo "[Base] SSH hardened OK"

# Lock sshd to localhost — all remote SSH access goes through Tailscale SSH.
echo 'ListenAddress 127.0.0.1' >> /etc/ssh/sshd_config
echo "[Base] SSH locked to localhost"
