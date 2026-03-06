# Kubernetes Architecture

## Cluster

Single K3s cluster on Hetzner Cloud. The control plane is HA (3 servers) in production, single-node in dev. Workers run application workloads.

```
Control Plane (3x) ── etcd (embedded)
       │
       ├── API Server (LB: lb-api :6443)
       └── Scheduler / Controller Manager

Worker Nodes (3x)
       └── Cilium (eBPF data plane, no kube-proxy)
       └── ingress-nginx (LB: lb-ingress :80/:443)
```

## Network

- **CNI:** Cilium with eBPF. kube-proxy disabled entirely (`--disable-kube-proxy` on K3s install).
- **WireGuard:** Cilium node-to-node encryption enabled.
- **Hubble:** Cilium's observability layer — flow logs and service maps.
- **Private network:** All cluster nodes on a Hetzner VPC (`10.0.1.0/24`). No public IPs on control plane or workers.
- **NAT gateway:** Single node with a public IP masquerades outbound traffic for private nodes.
- **Operator access:** Tailscale. Direct SSH/kubectl only via Tailscale mesh.

## IP Allocation (Hetzner VPC 10.0.1.0/24)

| Address | Role |
|---|---|
| `10.0.1.2` | NAT gateway |
| `10.0.1.11` | K3s API load balancer (internal) |
| `10.0.1.12` | Ingress load balancer (internal) |
| `10.0.1.21–23` | Control plane servers (server-cp-01, cp-02, cp-03) |
| `10.0.1.31–33` | Worker nodes (server-wk-01, wk-02, wk-03) |

## Bootstrap Order (ArgoCD sync-waves)

ArgoCD applications are ordered by `argocd.argoproj.io/sync-wave` annotations:

| Wave | App | Notes |
|---|---|---|
| 0 | Namespaces | Must exist before anything else |
| 1 | cert-manager | CRDs needed by ingress resources |
| 2 | Sealed Secrets | Must be running before any SealedSecret CRs |
| 3 | Cilium | Replaces K3s Flannel — applied at bootstrap, not via ArgoCD |
| 4 | ingress-nginx | Needs Cilium LB integration |
| 5 | ArgoCD | Self-manages after initial bootstrap |

## Security Posture (Single-Tenant)

No KubeArmor or Kyverno — those were for tenant isolation and are removed.

Current controls:
- **Network policies:** Cilium `CiliumNetworkPolicy` for namespace isolation
- **Pod Security:** Kubernetes built-in Pod Security Admission (`restricted` baseline for app namespaces)
- **Non-root:** All application containers run as non-root (enforced via PSA)
- **Secrets at rest:** Sealed Secrets — encrypted with cluster key, stored in Git
- **mTLS:** Cilium Mutual TLS for pod-to-pod communication within the cluster

## etcd Backups

etcd snapshots are written to S3-compatible storage (RustFS or any S3 endpoint) on a schedule. Variables `etcd_s3_*` in the Terraform configuration point to the backup target.

## Terraform Structure

```
infrastructure/terraform/
├── modules/
│   └── k3s_node/
│       ├── main.tf              # Core bootstrap — provider-agnostic
│       └── bootstrap/           # Core manifests only
│           ├── 110-cilium.yaml
│           ├── 120-ingress-nginx.yaml
│           ├── 130-sealed-secrets.yaml
│           ├── 140-argocd.yaml
│           └── 150-root-app.yaml
└── providers/
    └── hetzner/
        ├── main.tf              # Hetzner-specific resources + module call
        ├── firewall.tf
        ├── outputs.tf
        ├── templates/           # cloud-init templates
        └── bootstrap/           # hcloud-specific manifests
            ├── 000-hcloud-secret.yaml
            ├── 010-hcloud-ccm.yaml
            └── 020-hcloud-csi.yaml
```

The `k3s_node` module is provider-agnostic. It accepts an `extra_manifests` variable — a `map(string)` of rendered YAML — that the provider layer populates with its CCM secret, CCM, and CSI manifests. Adding a new provider means creating a new `providers/<name>/` directory; the shared module never changes.

## Resource Naming Convention

Pattern: `{env}-{region}-{type}[-{role}][-{index}]`

- `env` — `dev` or `prod` (`var.env`)
- `region` — plain human string: `eu-central`, `us-east`, `ap-southeast` (`var.region`)
- `type` — `net`, `server`, `lb`, `fw`, `nat`
- `role` — `cp` (control plane), `wk` (worker), `api`, `ingress`
- `index` — zero-padded: `01`, `02`, `03`

Examples: `dev-eu-central-server-cp-01`, `prod-us-east-lb-api`, `dev-eu-central-net`

Neither `env` nor `region` is derived from provider-specific codes. `var.region` doubles as the Hetzner `network_zone` value since Hetzner's zones (`eu-central`, `us-east`, `us-west`, `ap-southeast`) are already human-readable.
