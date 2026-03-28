# Runbook

Operational procedures for the platform. Single-operator context.

---

## Prerequisites

- `terraform`, `packer`, `helm`, `kubectl` installed
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

### 3. Deploy infrastructure
```sh
# Dev
task plan
task apply

# Prod
task plan:prod
task apply:prod
```

Dev creates: 1 NAT, 1 CP, 1 worker, 2 LBs, VPC.
Prod creates: 2 NAT (failover), 3 CP (HA), 3 workers, 2 LBs, VPC.

### 4. Connect to cluster
```sh
ssh root@<cp-init-tailscale-hostname>
cat /etc/kubernetes/admin.conf
```
Copy kubeconfig locally. Replace `127.0.0.1` with the Tailscale IP.

### 5. Verify bootstrap
```sh
kubectl get nodes
kubectl get pods -A
```
ArgoCD, Cilium, ingress-nginx, cert-manager, Sealed Secrets should all be running.

### 6. Seal secrets (post-bootstrap)
```sh
# Fetch the sealing cert
task cluster:fetch-cert

# Seal RustFS credentials
task cluster:seal TENANT=platform-system NAME=rustfs-credentials KEY=rootUser VAL='admin'
# Seal rootPassword separately

# Seal Grafana admin password
task cluster:seal TENANT=observability NAME=grafana-admin-secret KEY=GF_SECURITY_ADMIN_PASSWORD VAL='your-password' \
  DEST=infra/manifests/secrets/grafana-admin-secret.yaml
```
Commit and push the sealed secrets. ArgoCD syncs them automatically.

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

### Rotate
Re-seal with the current cert and push. ArgoCD syncs it.

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

## Teardown

```sh
# Dev
task destroy

# Prod
task destroy:prod
```
Destroys all Hetzner resources. Sealed Secrets keys are lost — re-sealing required on next bootstrap.

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
