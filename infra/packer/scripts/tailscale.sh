#!/bin/bash
set -euo pipefail
trap 'echo "[FATAL] tailscale.sh error on line $LINENO — exit code $?"' ERR

echo "=== Tailscale: Installing ==="
curl --proto =https -fsSL https://tailscale.com/install.sh | sh
systemctl enable tailscaled
rm -f /var/lib/tailscale/tailscaled.state
echo "[Tailscale] Installed and enabled OK"
