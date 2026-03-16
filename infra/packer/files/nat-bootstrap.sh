#!/bin/bash
set -euo pipefail

LOG="/var/log/nat-bootstrap.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== NAT Bootstrap Started at $(date) ==="

source /etc/nat-bootstrap.env

# 1. Apply private network netplan
netplan generate
netplan apply
sleep 5

# 2. Enable IP forwarding + disable UFW
sysctl -w net.ipv4.ip_forward=1
systemctl stop ufw || true
systemctl disable ufw || true

# 3. IPTables MASQUERADE (runtime — needs WAN interface detection)
WAN_IFACE=$(ip route show default | awk '{print $5}' | head -n1)
[ -z "$WAN_IFACE" ] && WAN_IFACE="eth0"
echo "WAN interface: $WAN_IFACE"

iptables -F FORWARD
iptables -t nat -F POSTROUTING
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -s 10.0.0.0/16 -j ACCEPT
iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
netfilter-persistent save
if ! test -s /etc/iptables/rules.v4; then
	echo "[FATAL] iptables rules not persisted — NAT will break on reboot"
	exit 1
fi
echo "iptables rules persisted to /etc/iptables/rules.v4"

# 4. Join Tailscale
echo "Waiting for tailscaled socket..."
for i in $(seq 1 12); do
	[ -S /run/tailscale/tailscaled.sock ] && break
	sleep 5
done
echo "tailscaled socket ready, joining..."
NEXT_WAIT=0
until tailscale up \
	--authkey="$TAILSCALE_AUTH_KEY" \
	--ssh \
	--hostname="$HOSTNAME" \
	--advertise-tags="tag:nat" \
	--reset >> "$LOG" 2>&1 \
	|| [ $NEXT_WAIT -eq 12 ]; do
	sleep 5
	NEXT_WAIT=$((NEXT_WAIT+1))
done

# 5. Start failover watchdog (secondary only)
if [ "${ROLE}" = "secondary" ]; then
	cat > /etc/nat-failover.env << EOF
PEER_NAT_IP=${PEER_NAT_IP}
HCLOUD_TOKEN=${HCLOUD_TOKEN}
HCLOUD_NETWORK_ID=${HCLOUD_NETWORK_ID}
EOF
	chmod 0600 /etc/nat-failover.env
	systemctl daemon-reload
	systemctl enable nat-failover.service
	systemctl start nat-failover.service
	echo "Failover watchdog started"
fi

echo "=== NAT Bootstrap Complete at $(date) ==="
