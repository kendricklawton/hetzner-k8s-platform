# Runbook

Operational procedures for the platform. Single-operator context.

---

## Prerequisites

- `terraform`, `packer`, `helm`, `kubectl`, `kubeseal` installed
- `.env` populated (copy from `.env.example`)
- GCP SA keys downloaded to `keys/`
- SSH key uploaded to Hetzner Cloud
- Tailscale API key + tailnet name

---

## Cluster Bootstrap

### 1. Set Let's Encrypt email
```sh
task cluster:set-email
```
Commit the updated `cluster-issuers.yaml` before deploying.

### 2. Build golden images
```sh
task packer
```
Produces two Hetzner snapshots in Ashburn: `role=k8s-node` and `role=nat-gateway`.

> Rebuild required any time `infra/packer/files/` changes. Terraform-only changes (versions, firewall rules, network config) do not require a Packer rebuild.

### 3. Deploy infrastructure
```sh
# Dev
task plan
task apply

# Prod
task plan:prod
task apply:prod
```

Dev creates: 1 NAT, 1 CP, 1 worker, 2 LBs, VPC (`10.0.0.0/8`).
Prod creates: 2 NAT (failover), 3 CP (HA), 3 workers, 2 LBs, VPC.

Bootstrap takes ~10 minutes. Monitor progress on the CP node:
```sh
ssh root@<cp-init-tailscale-hostname>
tail -f /var/log/k8s-bootstrap.log
```

### 4. Connect to cluster
```sh
ssh root@<cp-init-tailscale-hostname>
cat /etc/kubernetes/admin.conf
```
Copy kubeconfig locally. Replace `127.0.0.1` with the node's Tailscale IP.

### 5. Verify bootstrap
```sh
kubectl get nodes
kubectl get pods -A
```

Expected healthy bootstrap state:
- All nodes `Ready`
- Cilium, CoreDNS, Hubble running in `kube-system`
- Hetzner CCM and CSI running in `kube-system`
- Sealed Secrets running in `kube-system`
- ArgoCD pods running in `argocd`

ArgoCD will then begin syncing all other applications (cert-manager, ingress-nginx, observability stack, etc.). Full sync takes ~5 minutes.

### 6. Post-bootstrap
```sh
task cluster:post-bootstrap \
  GRAFANA_PASSWORD='your-password' \
  RUSTFS_USER='admin' \
  RUSTFS_PASSWORD='your-password'
```

This runs in sequence:
1. `cluster:fetch-cert` — fetches the Sealed Secrets public cert from the cluster
2. `cluster:seal-all` — seals all bootstrap secrets (Grafana, RustFS)
3. Prints next steps to commit and push

```sh
git add infra/manifests/secrets/
git commit -m 'seal bootstrap secrets'
git push
```

ArgoCD picks up the sealed secrets and deploys them automatically.

---

## ArgoCD

### Access
```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080
```

### Admin password
```sh
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

### Manual sync
```sh
argocd app sync <app-name>
```

---

## Sealed Secrets

### Seal a secret
```sh
task cluster:seal TENANT=<namespace> NAME=<secret-name> KEY=<key> VAL='<value>'
```
Output: `tenants/<TENANT>/<NAME>-sealed.yaml`. Move to the target path and commit.

To write directly to a specific path:
```sh
task cluster:seal TENANT=observability NAME=grafana-admin-secret \
  KEY=GF_SECURITY_ADMIN_PASSWORD VAL='password' \
  DEST=infra/manifests/secrets/grafana-admin-secret.yaml
```

### Rotate
Re-seal with the current cert and push. ArgoCD syncs it.

### Re-fetch cert (new cluster)
```sh
task cluster:fetch-cert
```
Saves to `keys/sealed-secrets-cert.pem`. Required after every cluster rebuild since the key pair is regenerated.

---

## Database (CNPG)

### Connect
```sh
kubectl exec -it -n platform-system \
  $(kubectl get pod -n platform-system -l role=primary -o name | head -1) \
  -- psql -U platform platform
```

---

## Backups

### etcd
Automated via CronJob at 02:00 UTC daily. Snapshots stored at `/var/lib/etcd-backup/` on control-plane nodes. Last 7 retained.

Manual backup (CKA pattern):
```sh
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd-backup.db
```

Manual restore:
```sh
etcdutl snapshot restore /tmp/etcd-backup.db --data-dir=/var/lib/etcd-restore
# Update etcd static pod manifest to point to new data-dir, then restart
```

### GCS backups
Backup SA keys are sealed into the cluster as Kubernetes secrets. Services (RustFS, CNPG) push to the per-env GCS backup bucket using prefixes:
- `postgres/`
- `etcd/`
- `rustfs/`
- `logs/`

---

## Deployments

1. Add manifests under `infra/manifests/<app-name>/` or a Helm chart reference
2. Add an ArgoCD `Application` CR under `infra/argocd/apps/`
3. Push to Git — ArgoCD auto-syncs via the env-specific Kustomize overlay

For TLS: add `cert-manager.io/cluster-issuer: letsencrypt` annotation to your Ingress.

---

## Networking Notes

**Native routing with Hetzner CCM:** Cilium uses native routing mode. The CCM registers per-node pod CIDR routes into the Hetzner VPC. The VPC must be `10.0.0.0/8` (not `/16`) to accept routes for `10.244.x.x` pod IPs. Without this, return traffic from the API server to pods is silently dropped.

**WireGuard encryption:** All pod-to-pod traffic between nodes is encrypted. The Cilium MTU is set via `$HCLOUD_MTU` (from cloud-init). Hetzner private network MTU is 1450.

**Firewall rules:** All internal rules use `10.0.0.0/8` to allow traffic from pod IPs in addition to node IPs.

---

## Teardown

```sh
# Dev
task destroy

# Prod
task destroy:prod
```
Destroys all Hetzner resources. Sealed Secrets keys are lost — `task cluster:fetch-cert` and re-sealing required on next bootstrap.

---

## Resource Naming

Pattern: `{env}-{location}-{type}[-{role}][-{index}]`

```
dev-ash-nat
dev-ash-net
dev-ash-lb-api
dev-ash-lb-ingress
dev-ash-server-cp-01
dev-ash-server-wk-01
```
