# Contributing to Hetzner K8s Platform

> **Personal infrastructure** — single operator, not a product.

---

## Codebase Layout

```
infra/
├── terraform/
│   ├── main.tf                    Hetzner Cloud resources (servers, LBs, network)
│   ├── firewall.tf                Role-specific firewalls (NAT, CP, worker)
│   ├── backups.tf                 GCS backup buckets + SA rotation
│   └── templates/                 cloud-init templates (kubeadm bootstrap)
├── packer/
│   ├── ubuntu.pkr.hcl             Golden image builds (NAT + K8s node)
│   └── scripts/                   Shared provisioner scripts (base, tailscale, cleanup)
├── argocd/
│   ├── apps/                      Base ArgoCD Application manifests (numbered by sync-wave)
│   └── envs/                      Kustomize overlays per environment
│       ├── dev/                   Dev overlay (Ashburn)
│       └── prod/                  Prod overlay (Ashburn)
└── manifests/                     Alert rules, PDBs, ClusterIssuers, secrets
Taskfile.yml                       All infra tasks (packer, terraform, backups, sealing)
```

---

## Tech Stack

| Layer          | Technology                                            |
|----------------|-------------------------------------------------------|
| Provider       | Hetzner Cloud (Ashburn, US)                           |
| Orchestration  | kubeadm (self-managed Kubernetes v1.32)               |
| IaC            | Terraform + Packer (hardened Ubuntu 24.04 images)     |
| GitOps         | ArgoCD (sync-wave ordered, Kustomize overlays)        |
| CNI            | Cilium (eBPF, replaces kube-proxy)                    |
| Ingress        | ingress-nginx + cert-manager (Let's Encrypt TLS)      |
| Secrets        | Sealed Secrets (encrypted at rest, committed to Git)  |
| Database       | CloudNativePG (operator-managed PostgreSQL)           |
| Object Storage | RustFS (S3-compatible)                                |
| Observability  | VictoriaMetrics + Grafana + Loki + Fluent Bit         |
| Operator Access| Tailscale overlay                                     |
| Backups        | GCS buckets (versioned) + rclone + etcd snapshots     |

---

## Rules of the House

1. **Hetzner only** — No AWS, GCP, Azure, Vercel, or managed Kubernetes. Bare cloud VMs with kubeadm.

2. **GitOps everything** — All cluster state lives in Git. ArgoCD syncs automatically. Manual `kubectl apply` is for emergencies only.

3. **Sealed Secrets** — Never commit plaintext secrets. Use `task cluster:seal` to encrypt with the cluster's public cert.

4. **Bootstrap-only exceptions** — Cilium, CCM, CSI, Sealed Secrets, and ArgoCD are installed via cloud-init because ArgoCD depends on them. Everything else is ArgoCD-managed.

5. **Environment parity** — Dev and prod use identical manifests. Environment-specific values (LB names) are patched via Kustomize overlays.

6. **Pinned versions** — Every Helm chart, container image, and binary uses a specific version tag. No `latest`, no `main`, no rolling tags.

7. **No SSH** — Operator access is via Tailscale + kubectl. SSH is a last resort for initial cert fetch (`task cluster:fetch-cert`).

---

## Development Setup

```bash
# Prerequisites: terraform, packer, kubectl, kubeseal, helm, task, gcloud CLI

# Copy and populate environment config
cp .env.example .env

# Set Let's Encrypt email
task cluster:set-email

# Build golden images
task packer

# Plan and apply infrastructure (dev)
task plan
task apply

# Fetch sealed secrets cert (one-time after bootstrap)
task cluster:fetch-cert

# Seal a secret
task cluster:seal TENANT=observability NAME=grafana-admin-secret \
  KEY=GF_SECURITY_ADMIN_PASSWORD VAL='your-password'
```

---

## Terraform Environments

```bash
# Dev (Ashburn)
task plan            # Plan
task apply           # Apply
task destroy         # Teardown

# Prod (Ashburn)
task plan:prod
task apply:prod
task destroy:prod
```

---

## Resource Naming Convention

Pattern: `{env}-{location}-{type}[-{role}][-{index}]`

```
dev-ash-nat
dev-ash-net
dev-ash-lb-api
dev-ash-lb-ingress
dev-ash-server-cp-01
dev-ash-server-wk-01
```

---

## ArgoCD Sync-Wave Order

| Wave | Components                                      |
|------|-------------------------------------------------|
| 0    | Namespaces, RuntimeClasses                      |
| 1    | cert-manager, NetworkPolicies, ResourcePolicies |
| 2    | ClusterIssuers, PDBs, ingress-nginx, CNPG, RustFS |
| 3    | Observability stack, alerts, backups, secrets    |
| 4    | Grafana                                         |

---

## Backup Operations

```bash
# Backup sealed secrets master key to GCS
task backup:sealed-secrets-key

# Restore-test etcd snapshot
task backup:test-etcd

# Restore-test CNPG Postgres backup
task backup:test-postgres
```
