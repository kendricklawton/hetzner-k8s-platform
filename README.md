# Hetzner K8s Platform

Self-hosted Kubernetes on Hetzner Cloud using kubeadm. Two environments (dev/prod), GitOps-managed with ArgoCD.

## Stack

| Component | Technology |
|---|---|
| Provider | Hetzner Cloud (Ashburn) |
| Orchestration | kubeadm (self-managed Kubernetes v1.32) |
| Provisioning | Terraform + Packer (hardened Ubuntu 24.04 images) |
| State backend | GCS (per-env buckets) |
| GitOps | ArgoCD (sync-wave ordered) |
| Network | Cilium (eBPF, native routing, WireGuard encryption, replaces kube-proxy) |
| Operator access | Tailscale SSH overlay (no public IPs on nodes) |
| Secrets | Sealed Secrets (encrypted at rest, committed to Git) |
| Database | CloudNativePG (PostgreSQL operator) |
| Object storage | RustFS (S3-compatible, in-cluster) |
| Observability | VictoriaMetrics + Grafana + Loki + Fluent Bit |
| Ingress | ingress-nginx + cert-manager (Let's Encrypt TLS) |
| Backups | GCS buckets (per-env) via RustFS + etcd snapshots (local) |

## Network Architecture

All nodes are on a private subnet with no public IPs. Outbound traffic routes through a NAT gateway. Operator access is via Tailscale.

| Range | Purpose |
|---|---|
| `10.0.0.0/8` | Hetzner VPC (must be `/8` to encompass pod + service CIDRs) |
| `10.0.1.0/24` | Node subnet (CP, workers, LBs, NAT) |
| `10.244.0.0/16` | Pod CIDR |
| `10.96.0.0/12` | Service CIDR |

Cilium runs in native routing mode. The Hetzner CCM registers per-node pod CIDR routes into the VPC so cross-node pod traffic is routed at the Hetzner network layer. WireGuard encrypts all pod-to-pod traffic between nodes.

## Project Structure

```
infra/
├── terraform/
│   ├── providers.tf               # Terraform/backend/provider config
│   ├── variables.tf               # Input variables
│   ├── main.tf                    # Resources (network, servers, LBs)
│   ├── firewall.tf                # Role-specific firewalls
│   ├── outputs.tf                 # Outputs
│   └── templates/                 # cloud-init templates (kubeadm bootstrap)
├── packer/
│   ├── ubuntu.pkr.hcl             # Golden image builds (Ashburn)
│   ├── files/                     # Baked bootstrap scripts
│   └── scripts/                   # Shared provisioner scripts
├── argocd/
│   ├── apps/                      # Base ArgoCD Application manifests
│   └── envs/                      # Kustomize overlays (dev/prod)
│       ├── dev/kustomization.yaml
│       └── prod/kustomization.yaml
└── manifests/                     # Alert rules, PDBs, ClusterIssuers, secrets
keys/                              # SA keys + sealed secrets cert (gitignored)
Taskfile.yml                       # All infra tasks
```

## Environments

| | Dev | Prod |
|---|---|---|
| Control planes | 1 | 3 (HA etcd) |
| Workers | 1 | 3 |
| NAT gateways | 1 | 2 (failover watchdog) |
| Naming | `dev-ash-*` | `prod-ash-*` |

## Workflow

```sh
# Build golden images (required when bootstrap scripts change)
task packer

# Dev
task plan              # Terraform plan
task apply             # Terraform apply
task destroy           # Teardown

# Prod
task plan:prod
task apply:prod
task destroy:prod

# Post-bootstrap (run after cluster is healthy)
task cluster:post-bootstrap \
  GRAFANA_PASSWORD='...' \
  RUSTFS_USER='admin' \
  RUSTFS_PASSWORD='...'
```

## Bootstrap vs ArgoCD-managed Components

Components installed during cloud-init (not managed by ArgoCD):

| Component | Reason |
|---|---|
| Cilium | ArgoCD needs networking to function |
| Hetzner CCM | Required for VPC pod routes |
| Hetzner CSI | Required for storage |
| Sealed Secrets | Required to decrypt secrets on first sync |
| ArgoCD | Manages everything else |

All other components are deployed and managed by ArgoCD via sync-waves.

## GCP Resources

GCP is used for Terraform state and backups only. No GCP resources are managed by Terraform.

| Resource | Purpose |
|---|---|
| `hetzner-k8s-platform-tfstate-dev` | Dev Terraform state |
| `hetzner-k8s-platform-tfstate-prod` | Prod Terraform state |
| `hetzner-k8s-platform-backups-dev` | Dev backups (etcd, DB, RustFS, logs) |
| `hetzner-k8s-platform-backups-prod` | Prod backups |

SA keys stored at `keys/gcp-tfstate-{env}.json` and `keys/gcp-backup-{env}.json`.
