# CLAUDE.md

## Project Overview

Production-grade, self-hosted Kubernetes platform on Hetzner Cloud. Immutable infrastructure (Packer golden images), provisioned with Terraform, bootstrapped with kubeadm, and managed via GitOps (ArgoCD). Two environments: dev (minimal) and prod (HA).

## Architecture

```
Taskfile.yml (orchestrator)
  -> Packer (golden images: NAT gateway + K8s node)
  -> Terraform (infra: network, servers, LBs, firewalls)
    -> cloud-init (injects env vars + runs kubeadm-bootstrap.sh)
      -> kubeadm init/join
      -> Cilium CNI (eBPF, WireGuard encryption, replaces kube-proxy)
      -> Hetzner CCM + CSI
      -> Sealed Secrets
      -> ArgoCD (root-app syncs infra/argocd/envs/{env})
        -> 23 applications deployed via sync-waves
```

**Cluster topology:**
- Dev: 1 CP, 1 worker, 1 NAT, 2 LBs
- Prod: 3 CP (HA etcd), 3 workers, 2 NATs (failover watchdog), 2 LBs

**Networking:** All nodes on private subnet 10.0.1.0/24 (no public IPs). Outbound via NAT gateway. Operator access via Tailscale SSH overlay. API server behind Hetzner LB on port 6443.

## Deployment Workflow

```bash
# 1. Configure environment
cp .env.example .env  # Fill in HCLOUD_TOKEN, TAILSCALE_API_KEY, etc.

# 2. Build golden images
task packer            # or packer:k8s / packer:nat individually

# 3. Deploy infrastructure
task plan && task apply

# 4. Post-bootstrap (after nodes are Ready)
task cluster:fetch-cert
task cluster:seal-all GRAFANA_PASSWORD=... RUSTFS_USER=... RUSTFS_PASSWORD=...
task cluster:set-email

# 5. Commit sealed secrets + push (ArgoCD auto-syncs)
git add infra/manifests/secrets/ && git commit && git push
```

## Key Conventions

### Variable Flow (Never Hardcode)

All configurable values flow through a pipeline. Never hardcode values in scripts that can be parameterized:

```
Taskfile.yml (source of truth for versions)
  -> TF_VAR_* env vars
    -> Terraform variables
      -> cloud-init template substitution (__PLACEHOLDER__)
        -> /etc/k8s-bootstrap.env on the node
          -> $VAR in kubeadm-bootstrap.sh
```

To add a new variable: define it in Taskfile vars, pass as TF_VAR in `_tf` task, add to `variables.tf`, add `replace()` in `main.tf`, add to cloud-init template, reference in bootstrap script.

### Bootstrap Components vs ArgoCD-Managed Components

**Bootstrap (installed during cloud-init, NOT managed by ArgoCD):**
- Cilium, Hetzner CCM, Hetzner CSI, Sealed Secrets, ArgoCD itself
- Versions pinned in Taskfile.yml
- Reason: ArgoCD can't manage itself or its own networking dependencies

**ArgoCD-managed (everything else):**
- Versions pinned in `infra/argocd/apps/*.yaml` helm parameters
- Deployed via sync-waves (0-4) to respect dependency order

### Sync Wave Order

| Wave | Components |
|------|-----------|
| 0 | Namespaces, RuntimeClasses |
| 1 | Kyverno, External Secrets, Cert-Manager |
| 2 | Ingress-nginx, CNPG, PDBs, ClusterIssuers, RustFS |
| 3 | Loki, Sealed Secrets (app), VM Alert Rules, CNPG Metrics |
| 4 | VictoriaMetrics, Grafana, Fluent-Bit, Trivy, OpenCost |

### ArgoCD Application Pattern

All apps use: automated sync (prune + selfHeal), ServerSideApply, retry with backoff (5 attempts). Source is always a Helm chart with inline values via `parameters`.

### Secrets

- Sensitive values are SealedSecrets committed to `infra/manifests/secrets/`
- Seal locally with `task cluster:seal` using the cluster's public cert (`keys/sealed-secrets-cert.pem`)
- The `keys/` directory is gitignored

### Network Policies

Default-deny ingress per namespace, explicit allow-lists. Egress is open. Policies live in `infra/argocd/apps/network-policies.yaml`.

### Kustomize Overlays

`infra/argocd/envs/{dev,prod}/kustomization.yaml` include all 23 app manifests. Prod applies patches (e.g., different LB names for ingress-nginx).

## File Structure

```
infra/
  terraform/
    main.tf              # Core resources (network, servers, LBs, cloud-init wiring)
    firewall.tf          # Role-based firewalls (NAT, CP, Worker)
    variables.tf         # Input variables
    providers.tf         # GCS backend, provider versions
    outputs.tf           # API endpoint, hostnames, IPs
    templates/           # cloud-init templates (cp-init, cp-join, worker, nat)
  packer/
    ubuntu.pkr.hcl       # NAT + K8s golden image definitions
    scripts/             # base.sh, tailscale.sh, cleanup.sh
    files/
      kubeadm-bootstrap.sh   # Main bootstrap (660+ lines, all roles)
      nat-bootstrap.sh       # NAT gateway setup
      nat-failover.sh        # Secondary NAT watchdog
  argocd/
    apps/                # 23 ArgoCD Application manifests
    envs/dev/            # Dev kustomization
    envs/prod/           # Prod kustomization (patches for HA)
  manifests/
    alerts/              # VMRule alert definitions
    cert-manager/        # ClusterIssuer manifests
    pdbs/                # PodDisruptionBudgets
    secrets/             # SealedSecret templates
```

## IP Address Map

| Resource | IP |
|----------|-----|
| Hetzner gateway | 10.0.0.1 |
| NAT primary | 10.0.1.2 |
| NAT secondary (prod) | 10.0.1.3 |
| API load balancer | 10.0.1.11 |
| Ingress load balancer | 10.0.1.12 |
| Control plane nodes | 10.0.1.21+ |
| Worker nodes | 10.0.1.31+ |

## Common Tasks

```bash
task packer:k8s          # Rebuild K8s node image only
task plan                # Terraform plan (dev)
task apply               # Terraform apply (dev)
task destroy             # Tear down dev cluster
task validate            # Run all static checks (TF, Packer, Kustomize, manifests)
task cluster:fetch-cert  # Get sealed-secrets public cert from cluster
task cluster:seal-all    # Seal all bootstrap secrets
task cluster:set-email   # Template LETS_ENCRYPT_EMAIL into ClusterIssuers
```

## Known Gotchas

- **API server DNS:** CP-init maps `api.platform.local` to its own private IP (not 127.0.0.1). Using loopback breaks Cilium eBPF routing inside pod network namespaces.
- **ArgoCD redis secret:** Pre-created during bootstrap to bypass the redis-secret-init job which fails on fresh clusters. Helm flag is `redis.secretInit.enabled=false` (not `redisSecretInit`).
- **Hetzner MTU:** Private network MTU is 1450. WireGuard adds ~60-80 bytes overhead. Cilium MTU must account for this when encryption is enabled.
- **No public IPs:** All SSH is via Tailscale. Nodes reach internet through NAT gateway only.
- **Packer rebuild required:** Any change to `kubeadm-bootstrap.sh` or other baked files requires `task packer:k8s` before `task apply`.
- **Helm `--reuse-values` on upgrades:** Can break on major version bumps (new chart fields get nil values). Use `--reset-then-reuse-values` instead.
- **Bootstrap env vars:** Variables in `/etc/k8s-bootstrap.env` are only available inside the bootstrap script, not in interactive SSH sessions.

## Component Versions (Taskfile.yml)

- Kubernetes: v1.32.13
- Cilium: 1.19.2
- Sealed Secrets: 2.18.4
- ArgoCD: 7.8.23
- Hetzner CCM: 1.30.1
- Hetzner CSI: 2.20.0

## Observability Stack

- **Metrics:** VictoriaMetrics (VMSingle, 30d retention, 20Gi)
- **Logs:** Loki (single-binary, 14d retention, 30Gi) + Fluent-Bit (container log shipping)
- **Dashboards:** Grafana (pre-loaded: node-exporter, k8s-cluster, k8s-pods, CNPG)
- **Alerts:** VMAlert -> Alertmanager (node health, pod crashes, PVC capacity, cert expiry)
- **Cost:** OpenCost (Hetzner pricing)
- **Security:** Trivy operator (vulnerability + config audit scanning)
