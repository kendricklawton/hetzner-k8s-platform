#!/bin/bash
set -euo pipefail

LOG="/var/log/k8s-bootstrap.log"
exec > >(tee -a "$LOG") 2>&1

# Trap errors with line number
trap 'echo "[FATAL] Error on line $LINENO — exit code $?" >> "$LOG"' ERR

source /etc/k8s-bootstrap.env

echo "=== K8s Bootstrap Started at $(date) ==="
echo "[Bootstrap] ROLE=$ROLE"
echo "[Bootstrap] HOSTNAME=$HOSTNAME"
echo "[Bootstrap] NETWORK_GATEWAY=${NETWORK_GATEWAY:-not set}"

# SHARED: Network + Tailscale + Metadata (all roles)

# 1. Apply netplan + restart resolver (brings up private network interface)
# Netplan config (baked by Packer) sets default route via 10.0.0.1 (Hetzner gateway).
# Hetzner's network route (created by Terraform) forwards 0.0.0.0/0 to the NAT at the network layer.
echo "[1/5 Network] Removing cloud-init netplan (conflicts with baked config)..."
rm -f /etc/netplan/50-cloud-init.yaml
echo "[1/5 Network] Applying netplan..."
netplan generate
netplan apply
sleep 2
systemctl restart systemd-networkd
sleep 3
systemctl restart systemd-resolved || true

echo "[1/5 Network] Interfaces:"
ip -4 addr show | grep -E 'inet |^[0-9]'
echo "[1/5 Network] Routes:"
ip route show
echo "[1/5 Network] DNS:"
resolvectl status 2>/dev/null | head -5 || cat /etc/resolv.conf

# 2. Add metadata route via Hetzner gateway
echo "[2/5 Routes] Adding metadata route..."
DEFAULT_DEV=$(ip -4 route show to default | awk '{print $5}' | head -1)
if [ -z "$DEFAULT_DEV" ]; then
	echo "[2/5 Routes] No default route found, looking for 10.0.x.x interface..."
	DEFAULT_DEV=$(ip -o -4 addr show | grep '10\.0\.' | awk '{print $2}' | head -1)
fi
if [ -n "$DEFAULT_DEV" ]; then
	ip route replace 169.254.169.254 via 10.0.0.1 dev "$DEFAULT_DEV" onlink || true
	echo "[2/5 Routes] Metadata route set on $DEFAULT_DEV"
else
	echo "[FATAL] No network device found"
	echo "[FATAL] ip addr output:"
	ip addr show
	exit 1
fi

# 3. Verify internet connectivity via NAT
echo "[3/5 Internet] Testing connectivity..."
for i in $(seq 1 12); do
	if curl -sf --connect-timeout 3 https://1.1.1.1 >/dev/null 2>&1; then
		echo "[3/5 Internet] OK — internet reachable via NAT"
		break
	fi
	echo "[3/5 Internet] Attempt $i/12 failed — retrying in 5s..."
	[ "$i" -eq 12 ] && {
		echo "[FATAL] No internet after 60s"
		echo "[FATAL] Default route: $(ip route show default)"
		echo "[FATAL] Can reach gateway? $(ping -c 1 -W 2 10.0.0.1 2>&1 || echo 'no')"
		echo "[FATAL] Can reach NAT? $(ping -c 1 -W 2 ${NETWORK_GATEWAY:-10.0.1.2} 2>&1 || echo 'no')"
		exit 1
	}
	sleep 5
done

# 4. Join Tailscale
echo "[4/5 Tailscale] Waiting for tailscaled socket..."
for i in $(seq 1 24); do
	if [ -S /run/tailscale/tailscaled.sock ]; then
		echo "[4/5 Tailscale] Socket ready (attempt $i)"
		break
	fi
	[ "$i" -eq 24 ] && { echo "[FATAL] tailscaled socket not found after 120s"; systemctl status tailscaled --no-pager || true; exit 1; }
	sleep 5
done
TS_TAG="tag:k8s-worker"
( [ "$ROLE" = "cp-init" ] || [ "$ROLE" = "cp-join" ] ) && TS_TAG="tag:k8s-cp"
echo "[4/5 Tailscale] Joining as $HOSTNAME with tag $TS_TAG..."
TS_ATTEMPTS=0
until tailscale up \
	--authkey="$TAILSCALE_AUTH_KEY" \
	--ssh --hostname="$HOSTNAME" --advertise-tags="$TS_TAG" --reset >> "$LOG" 2>&1; do
	TS_ATTEMPTS=$((TS_ATTEMPTS+1))
	echo "[4/5 Tailscale] Join failed (attempt $TS_ATTEMPTS) — retrying in 5s..."
	[ "$TS_ATTEMPTS" -ge 24 ] && { echo "[FATAL] Tailscale join failed after 24 attempts"; tailscale status 2>&1 || true; exit 1; }
	sleep 5
done
echo "[4/5 Tailscale] Joined successfully — $(tailscale ip -4 2>/dev/null || echo 'no IP yet')"

# 5. Wait for Hetzner metadata service
echo "[5/5 Metadata] Waiting for Hetzner metadata service..."
HCLOUD_ID=""
for i in $(seq 1 30); do
	HCLOUD_ID=$(curl -sf -m 3 http://169.254.169.254/hetzner/v1/metadata/instance-id 2>/dev/null || true)
	if [ -n "$HCLOUD_ID" ]; then
		echo "[Bootstrap] Hetzner instance ID: $HCLOUD_ID"
		break
	fi
	[ "$i" -eq 30 ] && echo "[FATAL] Metadata service unreachable after 60s"
	sleep 2
done
if [ -z "$HCLOUD_ID" ]; then
	echo "[FATAL] Cannot proceed without Hetzner instance ID — CCM/CSI will fail"
	exit 1
fi

# 5. Wait for Tailscale IP
echo "[Bootstrap] Waiting for Tailscale IP..."
TS_IP=""
for i in $(seq 1 30); do
	TS_IP=$(tailscale ip -4 2>/dev/null || true)
	if [ -n "$TS_IP" ]; then
		echo "[Bootstrap] Tailscale IP acquired: $TS_IP"
		break
	fi
	echo "[Bootstrap] Tailscale not ready yet (attempt $i/30)..."
	sleep 5
done
[ -z "$TS_IP" ] && echo "[WARN] Tailscale IP not available"

# ROLE-SPECIFIC BOOTSTRAP

# Hetzner LBs do not support hairpin routing — CP nodes cannot reach the API
# through the LB because they are backend targets of that same LB.
# Use a local DNS alias and point it at the right IP per role.
API_ENDPOINT_NAME="api.platform.local"
echo "[Bootstrap] Configuring local DNS resolution for API server..."
if [ "$ROLE" = "cp-init" ]; then
	echo "127.0.0.1 $API_ENDPOINT_NAME" >> /etc/hosts
elif [ "$ROLE" = "cp-join" ]; then
	echo "$CP_INIT_PRIVATE_IP $API_ENDPOINT_NAME" >> /etc/hosts
elif [ "$ROLE" = "worker" ]; then
	echo "$KUBERNETES_API_LB_IP $API_ENDPOINT_NAME" >> /etc/hosts
fi

case "$ROLE" in

# -------------------------------------------------------------
# CONTROL PLANE INIT
# -------------------------------------------------------------
cp-init)
	mkdir -p /var/log/kubernetes

	# Generate encryption config
	cat > /etc/kubernetes/encryption-config.yaml << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: "$ENCRYPTION_KEY"
      - identity: {}
EOF
	chmod 0600 /etc/kubernetes/encryption-config.yaml

	# Generate kubeadm config
	CERT_SANS="\"$HOSTNAME\", \"$KUBERNETES_API_LB_IP\", \"$API_ENDPOINT_NAME\", \"$NODE_PRIVATE_IP\", \"127.0.0.1\""
	[ -n "$TS_IP" ] && CERT_SANS="$CERT_SANS, \"$TS_IP\""

	cat > /etc/kubernetes/kubeadm-config.yaml << EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens:
  - token: "$KUBEADM_TOKEN"
    ttl: "24h"
certificateKey: "$KUBEADM_CERT_KEY"
nodeRegistration:
  name: "$HOSTNAME"
  criSocket: "unix:///run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: cloud-provider
      value: "external"
    - name: provider-id
      value: "hcloud://$HCLOUD_ID"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
controlPlaneEndpoint: "$API_ENDPOINT_NAME:6443"
apiServer:
  extraArgs:
    - name: audit-policy-file
      value: /etc/kubernetes/audit-policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit.log
    - name: audit-log-maxage
      value: "7"
    - name: audit-log-maxbackup
      value: "3"
    - name: audit-log-maxsize
      value: "10"
    - name: enable-admission-plugins
      value: "NodeRestriction"
    - name: encryption-provider-config
      value: /etc/kubernetes/encryption-config.yaml
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      readOnly: false
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption-config.yaml
      mountPath: /etc/kubernetes/encryption-config.yaml
      readOnly: true
  certSANs: [$CERT_SANS]
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
anonymous:
  enabled: false
authentication:
  webhook:
    enabled: true
authorization:
  mode: Webhook
readOnlyPort: 0
rotateCertificates: true
protectKernelDefaults: false
EOF
	chmod 0600 /etc/kubernetes/kubeadm-config.yaml

	# kubeadm init
	echo "[Bootstrap] Running kubeadm init..."
	kubeadm init \
		--config /etc/kubernetes/kubeadm-config.yaml \
		--skip-phases=addon/kube-proxy \
		--upload-certs \
		--ignore-preflight-errors=NumCPU

	export KUBECONFIG=/etc/kubernetes/admin.conf
	mkdir -p /root/.kube
	cp /etc/kubernetes/admin.conf /root/.kube/config

	# Serve CA cert hash for joining nodes (hash is public info — derived from public key)
	CA_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
		| openssl rsa -pubin -outform der 2>/dev/null \
		| openssl dgst -sha256 -hex | sed 's/^.* //')
	mkdir -p /tmp/ca-hash-server
	echo "sha256:$CA_HASH" > /tmp/ca-hash-server/index.html
	echo "[Bootstrap] CA cert hash: sha256:$CA_HASH"
	python3 -m http.server 9099 --directory /tmp/ca-hash-server --bind "$NODE_PRIVATE_IP" &>/dev/null &

	# Helm retry helper
	helm_retry() {
		local max_attempts=5
		local delay=15
		for attempt in $(seq 1 $max_attempts); do
			if "$@"; then
				return 0
			fi
			echo "[Bootstrap] Helm command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
			sleep $delay
		done
		echo "[FATAL] Helm command failed after $max_attempts attempts: $*"
		return 1
	}

	# Validate MTU + Install Cilium
	IFACE_MTU=$(ip -o link show dev enp7s0 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "unknown")
	if [ "$IFACE_MTU" != "unknown" ] && [ "$IFACE_MTU" != "$HCLOUD_MTU" ]; then
		echo "[WARN] MTU mismatch: interface enp7s0 has MTU $IFACE_MTU but Cilium configured with $HCLOUD_MTU"
	else
		echo "[Bootstrap] MTU validated: $IFACE_MTU (matches configured $HCLOUD_MTU)"
	fi

	echo "[Bootstrap] Installing Cilium $CILIUM_VERSION..."
	helm_retry helm repo add cilium https://helm.cilium.io/ --force-update
	helm_retry helm install cilium cilium/cilium \
		--version "$CILIUM_VERSION" \
		--namespace kube-system \
		--set k8sServiceHost="$API_ENDPOINT_NAME" \
		--set k8sServicePort=6443 \
		--set kubeProxyReplacement=true \
		--set mtu="$HCLOUD_MTU" \
		--set routingMode=native \
		--set autoDirectNodeRoutes=false \
		--set ipv4NativeRoutingCIDR="10.0.0.0/8" \
		--set endpointRoutes.enabled=true \
		--set ipam.mode=kubernetes \
		--set operator.replicas=1 \
		--set hubble.enabled=true \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--set devices=enp7s0 \
		--set encryption.enabled=true \
		--set encryption.type=wireguard

	echo "[Bootstrap] Waiting for Cilium to be ready..."
	kubectl rollout status daemonset/cilium -n kube-system --timeout=300s

	# Apply Hetzner cloud secret
	echo "[Bootstrap] Applying Hetzner cloud secret..."
	cat > /tmp/hcloud-secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: hcloud
  namespace: kube-system
stringData:
  token: "$HCLOUD_TOKEN_READONLY"
  network: "$HCLOUD_NETWORK_NAME"
EOF
	kubectl apply -f /tmp/hcloud-secret.yaml
	rm -f /tmp/hcloud-secret.yaml

	# Install Hetzner CCM
	echo "[Bootstrap] Installing Hetzner CCM $CCM_VERSION..."
	helm_retry helm repo add hcloud https://charts.hetzner.cloud --force-update
	helm_retry helm install hcloud-cloud-controller-manager hcloud/hcloud-cloud-controller-manager \
		--version "$CCM_VERSION" \
		--namespace kube-system \
		--set networking.enabled=true \
		--set networking.clusterCIDR="10.244.0.0/16"

	# Install Hetzner CSI
	echo "[Bootstrap] Installing Hetzner CSI $CSI_VERSION..."
	helm_retry helm install hcloud-csi hcloud/hcloud-csi \
		--version "$CSI_VERSION" \
		--namespace kube-system

	# Install Sealed Secrets
	echo "[Bootstrap] Installing Sealed Secrets $SEALED_SECRETS_VERSION..."
	helm_retry helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update
	helm_retry helm install sealed-secrets sealed-secrets/sealed-secrets \
		--version "$SEALED_SECRETS_VERSION" \
		--namespace kube-system \
		--set fullnameOverride=sealed-secrets

	# Install ArgoCD
	echo "[Bootstrap] Installing ArgoCD $ARGOCD_VERSION..."
	helm_retry helm repo add argo https://argoproj.github.io/argo-helm --force-update
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	# Pre-create the Redis secret to bypass the redis-secret-init pre-install job
	# which fails on fresh clusters due to network policy blocking egress to the API server.
	kubectl create secret generic argocd-redis \
		-n argocd \
		--from-literal=auth=$(openssl rand -base64 32) \
		--dry-run=client -o yaml | kubectl apply -f -
	helm_retry helm upgrade --install argocd argo/argo-cd \
		--version "$ARGOCD_VERSION" \
		--namespace argocd \
		--set server.insecure=true \
		--set redisSecretInit.enabled=false \
		--timeout 10m

	echo "[Bootstrap] Waiting for ArgoCD server to be ready..."
	kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

	# Apply root ArgoCD app
	echo "[Bootstrap] Applying ArgoCD root application..."
	cat > /tmp/root-app.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $GIT_REPO_URL
    targetRevision: HEAD
    path: $ARGOCD_APPS_PATH
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
	kubectl apply -f /tmp/root-app.yaml
	rm -f /tmp/root-app.yaml

	# Verify node health
	echo "[Bootstrap] Verifying cluster health..."
	for i in $(seq 1 20); do
		if kubectl get nodes 2>/dev/null | grep -q "$HOSTNAME"; then
			echo "[Bootstrap] Shutting down CA hash server..."
			kill $(lsof -t -i:9099) 2>/dev/null || true
			echo "=== K8s Control Plane Bootstrap Complete at $(date) ==="
			kubectl get nodes
			exit 0
		fi
		sleep 5
	done
	echo "[ERROR] Node $HOSTNAME not found in cluster after bootstrap"
	journalctl -u kubelet --no-pager --since "5min ago" | tail -50
	exit 1
	;;

# -------------------------------------------------------------
# CONTROL PLANE JOIN
# -------------------------------------------------------------
cp-join)
	mkdir -p /var/log/kubernetes

	# Generate encryption config
	cat > /etc/kubernetes/encryption-config.yaml << EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: "$ENCRYPTION_KEY"
      - identity: {}
EOF
	chmod 0600 /etc/kubernetes/encryption-config.yaml

	# Retrieve CA cert hash from cp-init
	echo "[Bootstrap] Retrieving CA cert hash from cp-init ($CP_INIT_PRIVATE_IP)..."
	CA_HASH=""
	for i in $(seq 1 60); do
		CA_HASH=$(curl -sf --connect-timeout 3 "http://$CP_INIT_PRIVATE_IP:9099/" 2>/dev/null || true)
		if [ -n "$CA_HASH" ]; then
			echo "[Bootstrap] CA cert hash: $CA_HASH"
			break
		fi
		[ "$((i % 10))" -eq 0 ] && echo "[Bootstrap] Waiting for CA hash (attempt $i/60)..."
		sleep 5
	done
	if [ -z "$CA_HASH" ]; then
		echo "[FATAL] Could not retrieve CA cert hash from cp-init after 5 minutes"
		exit 1
	fi

	# Generate kubeadm join config
	CERT_SANS="\"$HOSTNAME\", \"$KUBERNETES_API_LB_IP\", \"$API_ENDPOINT_NAME\", \"$NODE_PRIVATE_IP\", \"127.0.0.1\""
	[ -n "$TS_IP" ] && CERT_SANS="$CERT_SANS, \"$TS_IP\""

	cat > /etc/kubernetes/kubeadm-config.yaml << EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "$API_ENDPOINT_NAME:6443"
    token: "$KUBEADM_TOKEN"
    caCertHashes:
      - "$CA_HASH"
nodeRegistration:
  name: "$HOSTNAME"
  criSocket: "unix:///run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: cloud-provider
      value: "external"
    - name: provider-id
      value: "hcloud://$HCLOUD_ID"
controlPlane:
  certificateKey: "$KUBEADM_CERT_KEY"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
controlPlaneEndpoint: "$API_ENDPOINT_NAME:6443"
apiServer:
  extraArgs:
    - name: audit-policy-file
      value: /etc/kubernetes/audit-policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit.log
    - name: audit-log-maxage
      value: "7"
    - name: audit-log-maxbackup
      value: "3"
    - name: audit-log-maxsize
      value: "10"
    - name: enable-admission-plugins
      value: "NodeRestriction"
    - name: encryption-provider-config
      value: /etc/kubernetes/encryption-config.yaml
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      readOnly: false
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption-config.yaml
      mountPath: /etc/kubernetes/encryption-config.yaml
      readOnly: true
  certSANs: [$CERT_SANS]
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
anonymous:
  enabled: false
authentication:
  webhook:
    enabled: true
authorization:
  mode: Webhook
readOnlyPort: 0
rotateCertificates: true
protectKernelDefaults: false
EOF
	chmod 0600 /etc/kubernetes/kubeadm-config.yaml

	# Wait for API server
	echo "[Bootstrap] Waiting for API server at $API_ENDPOINT_NAME:6443..."
	for i in $(seq 1 60); do
		if curl -sk --connect-timeout 3 "https://$API_ENDPOINT_NAME:6443/healthz" >/dev/null 2>&1; then
			echo "[Bootstrap] API server is reachable"
			break
		fi
		[ "$i" -eq 60 ] && echo "[ERROR] API server not reachable after 5 minutes — joining anyway"
		sleep 5
	done

	echo "[Bootstrap] Running kubeadm join (control plane)..."
	kubeadm join --config /etc/kubernetes/kubeadm-config.yaml \
		--ignore-preflight-errors=NumCPU

	# Repoint local DNS to self now that we are a CP node
	sed -i "s/$CP_INIT_PRIVATE_IP $API_ENDPOINT_NAME/127.0.0.1 $API_ENDPOINT_NAME/" /etc/hosts

	export KUBECONFIG=/etc/kubernetes/admin.conf
	mkdir -p /root/.kube
	cp /etc/kubernetes/admin.conf /root/.kube/config

	# Verify node health
	echo "[Bootstrap] Verifying cluster health..."
	for i in $(seq 1 20); do
		if kubectl get nodes 2>/dev/null | grep -q "$HOSTNAME"; then
			echo "=== K8s Control Plane Bootstrap Complete at $(date) ==="
			kubectl get nodes
			exit 0
		fi
		sleep 5
	done
	echo "[ERROR] Node $HOSTNAME not found in cluster after bootstrap"
	journalctl -u kubelet --no-pager --since "5min ago" | tail -50
	exit 1
	;;

# -------------------------------------------------------------
# WORKER
# -------------------------------------------------------------
worker)
	# Retrieve CA cert hash from cp-init
	echo "[Bootstrap] Retrieving CA cert hash from cp-init ($CP_INIT_PRIVATE_IP)..."
	CA_HASH=""
	for i in $(seq 1 60); do
		CA_HASH=$(curl -sf --connect-timeout 3 "http://$CP_INIT_PRIVATE_IP:9099/" 2>/dev/null || true)
		if [ -n "$CA_HASH" ]; then
			echo "[Bootstrap] CA cert hash: $CA_HASH"
			break
		fi
		[ "$((i % 10))" -eq 0 ] && echo "[Bootstrap] Waiting for CA hash (attempt $i/60)..."
		sleep 5
	done
	if [ -z "$CA_HASH" ]; then
		echo "[FATAL] Could not retrieve CA cert hash from cp-init after 5 minutes"
		exit 1
	fi

	# Wait for API server
	echo "[Bootstrap] Waiting for API server at $API_ENDPOINT_NAME:6443..."
	for i in $(seq 1 60); do
		if curl -sk --connect-timeout 3 "https://$API_ENDPOINT_NAME:6443/healthz" >/dev/null 2>&1; then
			echo "[Bootstrap] API server is reachable"
			break
		fi
		[ "$i" -eq 60 ] && echo "[ERROR] API server not reachable after 5 minutes — joining anyway"
		sleep 5
	done

	# Generate kubeadm join config
	cat > /etc/kubernetes/kubeadm-config.yaml << EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "$API_ENDPOINT_NAME:6443"
    token: "$KUBEADM_TOKEN"
    caCertHashes:
      - "$CA_HASH"
nodeRegistration:
  name: "$HOSTNAME"
  criSocket: "unix:///run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: cloud-provider
      value: "external"
    - name: provider-id
      value: "hcloud://$HCLOUD_ID"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
anonymous:
  enabled: false
authentication:
  webhook:
    enabled: true
authorization:
  mode: Webhook
readOnlyPort: 0
rotateCertificates: true
protectKernelDefaults: false
EOF
	chmod 0600 /etc/kubernetes/kubeadm-config.yaml

	echo "[Bootstrap] Running kubeadm join (worker)..."
	kubeadm join --config /etc/kubernetes/kubeadm-config.yaml \
		--ignore-preflight-errors=NumCPU

	# Verify kubelet is active
	echo "[Bootstrap] Verifying worker node readiness..."
	for i in $(seq 1 12); do
		if systemctl is-active --quiet kubelet; then
			echo "[Bootstrap] kubelet service is active"
			break
		fi
		[ "$i" -eq 12 ] && { echo "[FATAL] kubelet not active after 60s"; journalctl -u kubelet --no-pager --since "2min ago" | tail -30; exit 1; }
		sleep 5
	done

	echo "=== K8s Worker Bootstrap Complete at $(date) ==="
	exit 0
	;;

*)
	echo "[FATAL] Unknown role: $ROLE"
	exit 1
	;;
esac
