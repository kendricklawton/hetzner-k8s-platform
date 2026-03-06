# Project Platform

A personal Kubernetes hosting platform for running my own applications on Hetzner Cloud with K3s. No external users. No tiers. No product. Just a clean, GitOps-managed cluster I can actually understand end-to-end.

## Purpose

- Host personal Go, Rust, and Zig applications
- Practice production-grade Kubernetes (CKA/CKS prep)
- Own the full stack from IaC to runtime

## Stack

### Application Layer
| Component | Technology |
|---|---|
| API server | Go (stdlib-first), plain HTTP via chi |
| Web dashboard | Go + Templ + HTMX + Alpine.js + Tailwind CSS |
| Auth | WorkOS OAuth — single user, session cookie `platform_session` |
| Database | PostgreSQL via pgx + sqlc (no ORM) |
| Object storage | RustFS (S3-compatible) |

### Infrastructure
| Component | Technology |
|---|---|
| Provider | Hetzner Cloud |
| Orchestration | K3s (lightweight Kubernetes) |
| Provisioning | Terraform + Packer (hardened Ubuntu images) |
| GitOps | ArgoCD (immutable, sync-wave ordered) |
| Network data plane | Cilium (eBPF, replaces kube-proxy) |
| Operator access | Tailscale |
| Secrets | Sealed Secrets (encrypted at rest, committed to Git) |
| Database operator | CloudNativePG (HA PostgreSQL) |
| Observability | VictoriaMetrics + Grafana + Loki + Fluent Bit |
| Ingress | ingress-nginx + cert-manager (Let's Encrypt TLS) |

## Project Structure

```
.
├── core/                          # Go module (github.com/kendricklawton/project-platform/core)
│   ├── cmd/
│   │   ├── platform-migrator/     # DB migration runner
│   │   ├── platform-server/       # Core API binary
│   │   └── platform-web/          # BFF web dashboard binary
│   └── internal/
│       ├── api/                   # Core API HTTP handlers
│       ├── config/                # Env-based config
│       ├── db/                    # pgx + sqlc generated layer
│       ├── k8s/                   # Kubernetes client
│       ├── server/                # Dependency wiring
│       ├── service/               # Business logic (auth)
│       └── web/                   # HTMX dashboard (handlers, router, templ pages)
├── infrastructure/
│   ├── argocd/                    # GitOps app manifests
│   │   └── apps/                  # ArgoCD Application CRDs
│   ├── packer/                    # Ubuntu golden image template
│   └── terraform/
│       ├── modules/k3s_node/      # K3s bootstrap manifests module
│       └── providers/hetzner/     # Hetzner Cloud IaC
├── CLAUDE.md                      # AI assistant protocol
├── K8s.md                         # Kubernetes architecture notes
├── POSTGRES.md                    # Database schema reference
├── RUNBOOK.md                     # Operational procedures
└── Taskfile.yml                   # Dev tasks
```

## Local Dev

```sh
task dev:web     # templ watch + Tailwind watch + Air (hot reload)
task dev:server  # Core API with Air
```

After any `.templ` edit: `templ generate` (or let the watcher handle it).  
After any Go edit: `go build ./...` from `core/` to verify before assuming success.
