# Project Platform

A high-performance PaaS for Go, Rust, and Zig static binary workloads. Built on bare metal with a focus on compiled language ecosystems, immutable infrastructure, and zero managed cloud dependencies.

## Stack

### Application Layer
| Component | Technology |
|---|---|
| API runtime | Go (stdlib-first), ConnectRPC over h2c |
| Web BFF | Go + Templ + HTMX + Alpine.js + Tailwind CSS |
| Auth | WorkOS OAuth — session cookie `platform_session` |
| Database | PostgreSQL via pgx + sqlc (no ORM) |
| Object storage | RustFS (S3-compatible) |

### Infrastructure
| Component | Technology |
|---|---|
| Bare metal | Hivelocity (Dallas hub) — 10 Gbps, 20 TB unmetered egress |
| Edge router | Hivelocity Floating IP → Traefik/Pingora on bare metal (zero egress cost) |
| Orchestration | K3s |
| Provisioning | Terraform + Packer (hardened Ubuntu golden images) |
| GitOps | ArgoCD (immutable, sync-wave ordered) |
| Network data plane | Cilium (eBPF) + Hubble observability + WireGuard mesh |
| Operator access | Tailscale overlay |
| Runtime isolation | gVisor (`runsc`) per tenant |
| Runtime security | KubeArmor (LSM enforcement) + Kyverno (policy validation) |
| Secrets | Sealed Secrets (encrypted at rest, committed to Git) |
| Database operator | CloudNativePG (HA PostgreSQL) |
| Observability | VictoriaMetrics + Grafana + Loki + Fluent Bit |
| Ingress | ingress-nginx + cert-manager (Let's Encrypt TLS) |

### Egress Architecture

All public traffic flows through a Hivelocity Floating IP mapped to the bare-metal edge node. This keeps egress entirely within Hivelocity's unmetered 20 TB/month bandwidth pool — avoiding per-GB billing from cloud VPS providers. The Floating IP can be reassigned to a secondary node via the Hivelocity API for zero-downtime failover.

## Project Structure

```
.
├── core/                          # Go monorepo (module: github.com/kendricklawton/project-platform/core)
│   ├── cmd/
│   │   ├── platform-cli/          # CLI binary
│   │   └── platform-web/          # BFF web server binary
│   ├── internal/
│   │   ├── api/                   # ConnectRPC handlers
│   │   ├── cli/                   # cobra commands + TUI
│   │   ├── config/                # env-based config
│   │   ├── server/                # dependency wiring
│   │   ├── service/               # business logic (auth, etc.)
│   │   └── web/                   # HTTP handlers, router, Templ UI
│   │       └── ui/
│   │           ├── components/    # layout shell
│   │           ├── pages/         # full + partial page components
│   │           ├── static/        # Tailwind compiled CSS
│   │           └── docs/          # markdown doc content
│   ├── migrations/                # golang-migrate SQL files
│   └── queries/                   # sqlc query definitions
├── infrastructure/
│   ├── packer/                    # golden image builds (Ubuntu + K3s + gVisor)
│   ├── kubernetes/                # ArgoCD app manifests + platform component configs
│   └── terraform/                 # resource provisioning
│       ├── modules/               # k3s_node, networking, floating_ip, etc.
│       └── providers/             # hivelocity/
├── proto/                         # Protobuf definitions
├── K8s.md                         # kubectl + K3s + ArgoCD + Cilium + CNPG command reference
├── POSTGRES.md                    # PostgreSQL + CNPG command reference
├── RUNBOOK.md                     # operational procedures
└── Taskfile.yml                   # dev/infra task runner
```

## Local Development

**Prerequisites:** Go, Docker, `go-task`, `templ`, `sqlc`, `buf`, `golangci-lint`

```bash
# 1. Clone
git clone https://github.com/kendricklawton/project-platform.git
cd project-platform

# 2. Environment
cp .env.example .env
# Populate .env with WORKOS_CLIENT_ID, WORKOS_CLIENT_SECRET, DATABASE_URL, etc.

# 3. Local database (Docker)
task db:setup   # brings up Postgres, runs migrations, runs sqlc generate

# 4. Run services (separate terminals)
task dev:server   # Core API — Air hot reload
task dev:web      # BFF web server — templ watch + Tailwind watch + Air
task dev:cli -- <args>   # CLI (build + run)
```

**Code generation:**
```bash
task proto:gen        # buf generate (ConnectRPC stubs)
task proto:lint       # buf lint
task db:generate      # sqlc generate
templ generate        # Templ → Go (or let dev:web watcher handle it)
```

**Database migrations:**
```bash
task db:create-migration NAME=<name>   # scaffold up/down files
task db:migrate                         # apply pending migrations
task db:migrate-down                    # roll back one step
task db:login                           # psql shell into local DB
```

After any change: `go build ./...` to verify no compilation errors.

## Infrastructure Operations

See [RUNBOOK.md](./RUNBOOK.md) for full provisioning, deployment, and incident response procedures.

Quick reference docs:
- [K8s.md](./K8s.md) — kubectl, K3s, ArgoCD, Cilium, CNPG, Sealed Secrets commands
- [POSTGRES.md](./POSTGRES.md) — PostgreSQL, CNPG, replication, backup commands

## Security Notes

- Containers run non-root. All public traffic TLS-terminated at ingress-nginx.
- Tenant workloads run under gVisor (`runsc`) for kernel-level isolation.
- KubeArmor LSM policies enforce per-pod syscall allow-lists.
- Kyverno validates all admission requests against platform policies.
- Secrets never live in plaintext in Git — use Sealed Secrets.

---

> Do not commit secrets, private keys, or service account JSON files. Use `.env` for local dev (gitignored). Use Sealed Secrets for in-cluster secrets.
