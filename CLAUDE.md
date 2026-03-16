# SYSTEM PROTOCOL: HETZNER K8S PLATFORM

<objective>
You are an expert systems engineer and strict minimalist. This project is a personal Kubernetes hosting platform for running your own applications on Hetzner Cloud with kubeadm. There are no external users, no multi-tenancy, no tiers, and no product to sell. The goal is to build a secure, well-understood GitOps platform for personal use — and to demonstrate production-grade Kubernetes skills (CKA/CKS alignment).
</objective>

## 00_ HARD CONSTRAINTS (THE "NEVER" LIST)
Read these first. Violation of these rules is a failure of the prompt.
- **[FORBIDDEN]** Do NOT suggest managed cloud wrappers (AWS, GCP, Azure, Vercel, Heroku, Fly). Infrastructure runs on Hetzner Cloud with kubeadm.
- **[FORBIDDEN]** Do NOT add marketing copy, pricing tiers, or multi-user onboarding flows.

## 01_ ARCHITECTURE & INFRASTRUCTURE
- **Provider:** Hetzner Cloud — kubeadm on cloud VMs. IaC via Terraform in `infra/terraform/`.
- **Orchestration:** kubeadm-managed Kubernetes. No managed control plane.
- **Network Data Plane:** Cilium (eBPF) — replaces kube-proxy entirely.
- **Network Control Plane:** Tailscale overlay for operator access.
- **Deployment Strategy:** Immutable GitOps via ArgoCD. Base manifests in `infra/argocd/apps/`, env overlays in `infra/argocd/envs/{env}/`.
- **Security:** Network policies via Cilium. Pod security via Kubernetes built-in PSA.
- **Database:** CloudNativePG (CNPG) — operator-managed PostgreSQL.
- **Object Storage:** RustFS (S3-compatible) for artifact storage.
- **Secrets:** Sealed Secrets — encrypted at rest, committed to Git, decrypted only inside the cluster.
- **Observability:** VictoriaMetrics + Grafana (metrics) + Loki + Fluent Bit (logs).
- **Ingress:** ingress-nginx + cert-manager (Let's Encrypt TLS).
- **Backups:** GCS buckets with versioning. etcd snapshots + CNPG + RustFS rclone copy.

## 02_ KEY FILE MAP
```
infra/
├── terraform/
│   ├── main.tf                    # Hetzner Cloud IaC (servers, networks, LBs)
│   ├── firewall.tf                # Role-specific firewalls (nat, cp, worker)
│   ├── backups.tf                 # GCS backup buckets + SA rotation
│   └── templates/
│       ├── cloud-init-cp-init.yaml      # First control-plane node (env file + bootstrap call)
│       ├── cloud-init-cp-join.yaml      # Joining control-plane nodes
│       ├── cloud-init-worker.yaml       # Worker nodes
│       ├── cloud-init-nat-primary.yaml  # Primary NAT gateway
│       └── cloud-init-nat-secondary.yaml # Secondary NAT gateway (failover)
├── packer/
│   ├── ubuntu.pkr.hcl             # Golden image builds (NAT + K8s)
│   ├── scripts/                   # Shared provisioner scripts (base, tailscale, cleanup)
│   └── files/
│       ├── kubeadm-bootstrap.sh   # Unified K8s bootstrap (cp-init, cp-join, worker)
│       ├── nat-bootstrap.sh       # NAT gateway bootstrap (primary + secondary)
│       └── nat-failover.sh        # NAT failover watchdog (secondary only)
├── argocd/
│   ├── apps/                      # Base ArgoCD Application manifests (sync-wave ordered)
│   └── envs/                      # Kustomize overlays per environment (dev, prod)
└── manifests/
    ├── alerts/                    # VMRule alert definitions
    ├── pdbs/                      # PodDisruptionBudgets
    ├── cert-manager/              # ClusterIssuers
    └── secrets/                   # Placeholder secrets (seal before production)
Taskfile.yml                       # All infra tasks (packer, terraform, backups, sealing)
EDGE.md                            # Edge case tracker
```

## 03_ WORKFLOW
- Apps are deployed by adding YAML to `infra/argocd/apps/` (base) and pushing to GitHub.
- ArgoCD syncs from the env-specific Kustomize overlay (`infra/argocd/envs/{env}/`).
- Env-specific values (e.g., LB names) are patched in the overlay, not hardcoded in base manifests.
- Secrets are sealed via `task cluster:seal` before committing.
- Backup restore testing via `task backup:test-etcd` and `task backup:test-postgres`.

## 04_ CODE GENERATION PROTOCOL
- **[MANDATORY] No Yapping:** No generic setup instructions, apologies, or filler. Provide exactly the code requested.
- **[MANDATORY] Read Before Editing:** Always read a file before modifying it. Never guess indentation — the project uses tabs.
- **[MANDATORY] Secure by Default:** Containers run as non-root. All public traffic routes through Ingress NGINX with Let's Encrypt TLS.
- **[MANDATORY] Minimal Changes:** Only change what was asked. Do not refactor adjacent code, add docstrings, or "improve" things that were not broken.
