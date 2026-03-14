#!/bin/bash
# Shared Tailscale installation for all golden images
set -euo pipefail

echo "=== Tailscale: Installing ==="
curl --proto =https -fsSL https://tailscale.com/install.sh | sh
systemctl enable tailscaled
rm -f /var/lib/tailscale/tailscaled.state
