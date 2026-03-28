#!/bin/bash
set -euo pipefail

source /etc/nat-failover.env

PRIMARY_IP="$PEER_NAT_IP"
MY_IP=$(ip -4 addr show | grep "10\.0\.1\." | awk '{print $2}' | cut -d/ -f1 | head -1)
NETWORK_ID="$HCLOUD_NETWORK_ID"
TOKEN="$HCLOUD_TOKEN"
API="https://api.hetzner.cloud/v1"
LOG="/var/log/nat-failover.log"

FAIL_COUNT=0
FAIL_THRESHOLD=3
CHECK_INTERVAL=10
IS_ACTIVE=false

echo "[failover] Watchdog started at $(date)" >> "$LOG"
echo "[failover] Monitoring primary at $PRIMARY_IP, my IP is $MY_IP" >> "$LOG"

while true; do
	if ping -c 1 -W 3 "$PRIMARY_IP" > /dev/null 2>&1; then
		FAIL_COUNT=0
	else
		FAIL_COUNT=$((FAIL_COUNT + 1))
		echo "[failover] Primary unreachable ($FAIL_COUNT/$FAIL_THRESHOLD) at $(date)" >> "$LOG"

		if [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ] && [ "$IS_ACTIVE" = false ]; then
			echo "[failover] TAKING OVER — deleting old route and switching to $MY_IP at $(date)" >> "$LOG"

			DELETE_RESP=$(curl -sf -X POST "$API/networks/$NETWORK_ID/actions/delete_route" \
				-H "Authorization: Bearer $TOKEN" \
				-H "Content-Type: application/json" \
				-d "{\"destination\":\"0.0.0.0/0\",\"gateway\":\"$PRIMARY_IP\"}" 2>&1 || echo "DELETE FAILED")
			echo "[failover] Delete route response: $DELETE_RESP" >> "$LOG"

			sleep 2

			ADD_RESP=$(curl -sf -X POST "$API/networks/$NETWORK_ID/actions/add_route" \
				-H "Authorization: Bearer $TOKEN" \
				-H "Content-Type: application/json" \
				-d "{\"destination\":\"0.0.0.0/0\",\"gateway\":\"$MY_IP\"}" 2>&1 || echo "ADD FAILED")
			echo "[failover] Add route response: $ADD_RESP" >> "$LOG"

			IS_ACTIVE=true
			echo "[failover] Route switched to self at $(date)" >> "$LOG"
		fi
	fi
	sleep $CHECK_INTERVAL
done
