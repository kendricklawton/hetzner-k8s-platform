# Hetzner K8s Platform

Self-hosted Kubernetes on Hetzner Cloud using kubeadm. Two environments (dev/prod), GitOps-managed with ArgoCD, built for CKA exam practice.

## Stack

| Component | Technology |
|---|---|
| Provider | Hetzner Cloud (Ashburn) |
| Orchestration | kubeadm (self-managed Kubernetes v1.32) |
| Provisioning | Terraform + Packer (hardened Ubuntu 24.04 images) |
| State backend | GCS (per-env buckets) |
| GitOps | ArgoCD (sync-wave ordered) |
| Network | Cilium (eBPF, replaces kube-proxy) |
| Operator access | Tailscale SSH overlay (no public IPs on nodes) |
| Secrets | Sealed Secrets (encrypted at rest, committed to Git) |
| Database | CloudNativePG (PostgreSQL operator) |
| Object storage | RustFS (S3-compatible, in-cluster) |
| Observability | VictoriaMetrics + Grafana + Loki + Fluent Bit |
| Ingress | ingress-nginx + cert-manager (Let's Encrypt TLS) |
| Backups | GCS buckets (per-env) via RustFS + etcd snapshots (local) |

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
| Control planes | 1 | 3 (HA) |
| Workers | 1 | 3 |
| NAT gateways | 1 | 2 (failover) |
| Naming | `dev-ash-*` | `prod-ash-*` |

## Workflow

```sh
# Build golden images
task packer

# Dev
task plan              # Terraform plan
task apply             # Terraform apply
task destroy           # Teardown

# Prod
task plan:prod
task apply:prod
task destroy:prod

# Post-bootstrap
task cluster:fetch-cert
task cluster:seal TENANT=platform-system NAME=rustfs-credentials KEY=rootUser VAL='admin'
task cluster:set-email
```

## GCP Resources

GCP is used for Terraform state and backups only. No GCP resources are managed by Terraform.

| Resource | Purpose |
|---|---|
| `hetzner-k8s-platform-tfstate-dev` | Dev Terraform state |
| `hetzner-k8s-platform-tfstate-prod` | Prod Terraform state |
| `hetzner-k8s-platform-backups-dev` | Dev backups (etcd, DB, RustFS, logs) |
| `hetzner-k8s-platform-backups-prod` | Prod backups |

SA keys stored at `keys/gcp-tfstate-{env}.json` and `keys/gcp-backup-{env}.json`.
