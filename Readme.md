# Hetzner K8s Platform

A personal Kubernetes hosting platform for running my own applications on Hetzner Cloud with kubeadm. No external users. No tiers. No product. Just a clean, GitOps-managed cluster I can actually understand end-to-end.

## Purpose

- Host personal applications on cheap Hetzner compute
- Practice production-grade Kubernetes (CKA/CKS prep)
- Own the full stack from IaC to runtime

## Stack

| Component | Technology |
|---|---|
| Provider | Hetzner Cloud |
| Orchestration | kubeadm (self-managed Kubernetes) |
| Provisioning | Terraform + Packer (hardened Ubuntu images) |
| GitOps | ArgoCD (immutable, sync-wave ordered) |
| Network data plane | Cilium (eBPF, replaces kube-proxy) |
| Operator access | Tailscale overlay |
| Secrets | Sealed Secrets (encrypted at rest, committed to Git) |
| Database operator | CloudNativePG (HA PostgreSQL) |
| Object storage | RustFS (S3-compatible) |
| Observability | VictoriaMetrics + Grafana + Loki + Fluent Bit |
| Ingress | ingress-nginx + cert-manager (Let's Encrypt TLS) |
| Backups | GCS buckets (versioned) + rclone + etcd snapshots |

## Project Structure

```
infra/
├── terraform/
│   ├── main.tf                    # Hetzner Cloud IaC
│   ├── firewall.tf                # Role-specific firewalls
│   ├── backups.tf                 # GCS backup buckets + SA rotation
│   └── templates/                 # cloud-init templates (kubeadm bootstrap)
├── packer/
│   ├── ubuntu.pkr.hcl             # Golden image builds
│   └── scripts/                   # Shared provisioner scripts
├── argocd/
│   ├── apps/                      # Base ArgoCD Application manifests
│   └── envs/                      # Kustomize overlays per environment
│       ├── dev/                   # Dev overlay (Ashburn)
│       └── prod/                  # Prod overlay (Ashburn)
└── manifests/                     # Alert rules, PDBs, ClusterIssuers, secrets
Taskfile.yml                       # Infra tasks (packer, terraform, backups, sealing)
EDGE.md                            # Edge case tracker
```

## Workflow

Deploy apps by adding YAML to `infra/argocd/apps/` and pushing to GitHub. ArgoCD syncs automatically via the env-specific Kustomize overlay.

```sh
task plan            # Terraform plan (dev)
task apply           # Terraform apply (dev)
task plan:prod       # Terraform plan (prod)
task apply:prod      # Terraform apply (prod)
task packer          # Build golden images
task cluster:seal    # Seal a secret for the cluster
```
