# K8s Platform

Self-managed Kubernetes on Hetzner Cloud using kubeadm. GitOps-driven via ArgoCD — git push deploys everything. Terraform is applied manually via the task runner.

## Stack

| Component | Technology |
|---|---|
| Provider | Hetzner Cloud (Ashburn) |
| Orchestration | kubeadm (self-managed Kubernetes v1.32) |
| Provisioning | Terraform + Packer (hardened Ubuntu 24.04 golden images) |
| State + backups | GCS (Hetzner has no native object storage) |
| GitOps | ArgoCD (sync-wave ordered) |
| Networking | Cilium (eBPF, native routing, WireGuard pod encryption, replaces kube-proxy) |
| Operator access | Tailscale SSH (no public IPs on any node) |
| Secrets | Sealed Secrets (encrypted at rest, committed to Git) |
| Certificates | cert-manager (Let's Encrypt) |
| Ingress | ingress-nginx |
| Database | CloudNativePG (PostgreSQL operator) |
| Object storage | RustFS (S3-compatible, in-cluster) |
| Observability | VictoriaMetrics + Grafana + Loki + Fluent Bit |
| Policy | Kyverno |
| Vulnerability scanning | Trivy Operator |
| Cost visibility | OpenCost |

## Repository Structure

```
Taskfile.yml
infra/
├── taskfiles/
│   ├── hetzner.yml      # Packer + Terraform + kubeconfig + bootstrap
│   ├── cluster.yml      # Sealed Secrets, cert, post-bootstrap
│   └── validate.yml     # Static validation
├── terraform/
│   └── hetzner/         # VPC, NAT VM, servers, LBs, firewall, cloud-init
├── packer/
│   └── hetzner/         # Golden images: NAT gateway + K8s node
│       ├── ubuntu.pkr.hcl
│       ├── files/        # Baked bootstrap scripts (kubeadm, NAT, failover)
│       └── scripts/      # Shared provisioners (base, tailscale, cleanup)
├── argocd/
│   ├── apps/             # ArgoCD Application manifests
│   └── envs/
│       ├── hetzner-dev/  # Kustomize overlay — dev patches
│       └── hetzner-prod/ # Kustomize overlay — prod patches
└── manifests/            # Alerts, PDBs, ClusterIssuers, Sealed Secrets
keys/                     # GCS SA keys + Sealed Secrets cert (gitignored)
```

## Network

All nodes are private — no public IPs. Outbound traffic routes through a NAT gateway VM. Operator access is exclusively via Tailscale SSH.

| Range | Purpose |
|---|---|
| `10.0.0.0/8` | VPC (must be `/8` — pod CIDRs must fit inside) |
| `10.0.1.0/24` | Node subnet |
| `10.244.0.0/16` | Pod CIDR |
| `10.96.0.0/12` | Service CIDR |

Cilium runs in native routing mode. The Hetzner CCM registers per-node pod CIDR routes into the VPC so cross-node pod traffic is routed at the Hetzner network layer. WireGuard encrypts all pod-to-pod traffic.

## Environments

| | Dev | Prod |
|---|---|---|
| Control planes | 1 | 3 (HA etcd) |
| Workers | 1 | 3 |
| NAT gateways | 1 | 2 (failover watchdog) |
| Naming | `dev-ash-*` | `prod-ash-*` |

## Prerequisites

- `terraform`, `packer`, `helm`, `kubectl`, `kubeseal`, `task`, `gcloud` installed
- `.env` populated from `.env.example`
- GCS SA keys at `keys/gcp-tfstate-{dev,prod}.json`
- SSH key uploaded to Hetzner Cloud
- Tailscale API key + tailnet configured

Run `task validate:env` to check everything before starting.

---

## Bootstrap

### 1. One-time setup

```sh
# Set Let's Encrypt email in ClusterIssuers and commit
task cluster:set-email

# Set your Git repo URL in ArgoCD app manifests and commit
task cluster:set-repo
```

### 2. Build golden images

```sh
task hetzner:packer
```

Produces two Hetzner snapshots in Ashburn: `role=k8s-node` and `role=nat-gateway`.

> Rebuild only when `infra/packer/hetzner/files/` changes. Terraform-only changes (versions, firewall rules, sizing) do not need a Packer rebuild.

### 3. Provision infrastructure

```sh
task hetzner:plan
task hetzner:apply
```

Dev: 1 CP, 1 worker, 1 NAT, 2 LBs (~10 min bootstrap via cloud-init).
Prod: 3 CP (HA etcd), 3 workers, 2 NAT (failover), 2 LBs.

Monitor bootstrap on the CP node:
```sh
ssh root@<cp-tailscale-hostname>
tail -f /var/log/k8s-bootstrap.log
```

### 4. Fetch kubeconfig

```sh
task hetzner:kubeconfig        # saves to keys/kubeconfig-hetzner-dev
export KUBECONFIG=$PWD/keys/kubeconfig-hetzner-dev
```

### 5. Verify cluster health

```sh
kubectl get nodes
kubectl get pods -A
```

Expected healthy state:
- All nodes `Ready`
- Cilium, CoreDNS, Hubble running in `kube-system`
- Hetzner CCM and CSI running in `kube-system`
- Sealed Secrets running in `kube-system`
- ArgoCD running in `argocd`

ArgoCD then syncs all platform apps automatically (~5 min).

### 6. Post-bootstrap

```sh
task hetzner:bootstrap \
  GRAFANA_PASSWORD='...' \
  RUSTFS_USER='admin' \
  RUSTFS_PASSWORD='...'
```

This runs: `cluster:fetch-cert` → `cluster:seal-all` → prints commit instructions.

```sh
git add infra/manifests/secrets/
git commit -m 'seal bootstrap secrets'
git push
```

ArgoCD picks up the sealed secrets and deploys them.

---

## Common Operations

### Infrastructure changes
```sh
task hetzner:plan         # dev
task hetzner:apply
task hetzner:plan:prod    # prod
task hetzner:apply:prod
task hetzner:destroy      # prompts for confirmation
task hetzner:destroy:prod # prompts for confirmation
```

### App and config changes
Edit files under `infra/argocd/` or `infra/manifests/` → push. ArgoCD auto-syncs.

**Add a new app:**
1. Create `infra/argocd/apps/<name>.yaml`
2. Add to `infra/argocd/envs/hetzner-dev/kustomization.yaml` (and prod)
3. Push

For TLS: add `cert-manager.io/cluster-issuer: letsencrypt-prod` to your Ingress.

### Seal a secret
```sh
task cluster:seal TENANT=<ns> NAME=<name> KEY=<key> VAL='<value>'

# Write directly to a specific path:
task cluster:seal TENANT=observability NAME=grafana-admin-secret \
  KEY=GF_SECURITY_ADMIN_PASSWORD VAL='...' \
  DEST=infra/manifests/secrets/grafana-admin-secret.yaml
```

### Re-fetch Sealed Secrets cert (after cluster rebuild)
```sh
task cluster:fetch-cert
```
The key pair regenerates on every rebuild — re-seal all secrets after.

### ArgoCD access
```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

### Database (CNPG)
```sh
kubectl exec -it -n platform-system \
  $(kubectl get pod -n platform-system -l role=primary -o name | head -1) \
  -- psql -U platform platform
```

### Validate before pushing
```sh
task validate        # all checks
task validate:env    # .env + files + tools
```

---

## Bootstrap-only Components

Installed during cloud-init — not managed by ArgoCD because ArgoCD depends on them:

| Component | Reason |
|---|---|
| Cilium | ArgoCD needs networking to operate |
| Hetzner CCM | Registers per-node pod CIDR routes in the VPC |
| Hetzner CSI | Provides PersistentVolume StorageClass |
| Sealed Secrets | Decrypts secrets before ArgoCD first sync |
| ArgoCD | Bootstraps itself, then manages everything else |

## Backups

etcd: automated CronJob at 02:00 UTC daily. Snapshots at `/var/lib/etcd-backup/` (last 7 retained) and pushed to `HETZNER_BACKUP_BUCKET_{DEV,PROD}`.

Manual snapshot:
```sh
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd-backup.db
```

## Teardown

```sh
task hetzner:destroy        # dev — prompts for confirmation
task hetzner:destroy:prod   # prod — prompts for confirmation
```

Teardown loses the Sealed Secrets key pair. Run `task cluster:fetch-cert` and re-seal all secrets after the next bootstrap.

## Resource Naming

`{env}-{location}-{type}[-{index}]` — e.g. `dev-ash-cp-01`, `prod-ash-wk-02`, `dev-ash-lb-ingress`
