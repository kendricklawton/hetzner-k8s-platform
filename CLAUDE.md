# SYSTEM PROTOCOL: PROJECT PLATFORM

<objective>
You are an expert systems engineer and strict minimalist. This project is a personal Kubernetes hosting platform for running your own applications on Hetzner Cloud with K3s. There are no external users, no multi-tenancy, no tiers, and no product to sell. The goal is to build a secure, well-understood GitOps platform for personal use — and to demonstrate production-grade Kubernetes skills (CKA/CKS alignment).
</objective>

## 00_ HARD CONSTRAINTS (THE "NEVER" LIST)
Read these first. Violation of these rules is a failure of the prompt.
- **[FORBIDDEN]** Do NOT suggest managed cloud wrappers (AWS, GCP, Azure, Vercel, Heroku, Fly). Infrastructure runs on Hetzner Cloud with K3s.
- **[FORBIDDEN]** Do NOT write React, Vue, Svelte, or SPA JavaScript. The frontend is HTMX + Alpine.js + Templ.
- **[FORBIDDEN]** Do NOT use GORM, Prisma, or heavy ORMs. Raw SQL via `sqlc` or `pgx` only.
- **[FORBIDDEN]** Do NOT use reflection-based dependency injection frameworks.
- **[FORBIDDEN]** Do NOT output rounded corners (`rounded-md`, `rounded-full`, etc.) in UI code unless specifically rendering a status dot or avatar.
- **[FORBIDDEN]** Do NOT add marketing copy, pricing tiers, or multi-user onboarding flows.

## 01_ ARCHITECTURE & INFRASTRUCTURE
- **Provider:** Hetzner Cloud — K3s on cloud VMs. IaC via Terraform in `infrastructure/terraform/providers/hetzner/`.
- **Orchestration:** K3s — lightweight Kubernetes. No managed control plane.
- **Network Data Plane:** Cilium (eBPF) — replaces kube-proxy entirely.
- **Network Control Plane:** Tailscale overlay for operator access.
- **Deployment Strategy:** Immutable GitOps via ArgoCD. Bootstrap manifests in `infrastructure/terraform/modules/k3s_node/bootstrap/`.
- **Security:** Network policies via Cilium. Pod security via Kubernetes built-in PSA (no KubeArmor/Kyverno — removed, not needed for single-tenant).
- **Database:** CloudNativePG (CNPG) — operator-managed PostgreSQL.
- **Object Storage:** RustFS (S3-compatible) for artifact and build storage.
- **Secrets:** Sealed Secrets — encrypted at rest, committed to Git, decrypted only inside the cluster.
- **Observability:** VictoriaMetrics + Grafana (metrics) + Loki + Fluent Bit (logs).
- **Ingress:** ingress-nginx + cert-manager (Let's Encrypt TLS).

## 02_ BACKEND STRATEGY (CORE API)
- **Runtime:** Go (Standard Library absolute priority). Module path: `github.com/kendricklawton/project-platform/core`.
- **Transport:** Plain HTTP (`net/http` + chi) for all routes. No ConnectRPC/gRPC.
- **Data Persistence:** PostgreSQL via `pgx` and `sqlc`-generated queries. No ORM.
- **Architecture:** Explicit dependency injection wired in `server.go`. No magic.
- **Auth:** WorkOS OAuth flow (single user). Session cookie `platform_session`. `RequireAuth` chi middleware guards protected routes.
- **Philosophy [ZERO-SDK]:** Standard Library and Linux primitives first. Third-party packages require explicit justification.

## 03_ FRONTEND STRATEGY (WEB BFF)
- **Stack:** Go + Templ + HTMX + Alpine.js + Tailwind CSS. Served by `platform-web` binary.
- **Interaction Model:** HTMX partial DOM swaps targeting `#dashboard-content`. Full-page navigations only for auth flows.
- **HTMX Swap Pattern:** Dashboard pages use `DashboardLayout` with `isDashboardSwap(r)` check. Settings/account pages use `Layout` with `isMainContentSwap(r)` check.
- **Routing:** `chi` router. `/` → redirect. Auth routes public. All dashboard routes behind `RequireAuth` middleware.
- **Icons:** Lucide CDN (`data-lucide="icon-name"`). `lucide.createIcons()` called on `DOMContentLoaded` and `htmx:afterSwap`.
- **Theme:** Dual-mode. Light = Tailwind `zinc` scale. Dark = Atom One Dark (`atom-bg`, `atom-surface`, `atom-border`, `atom-fg`, `atom-muted`, `atom-blue`, `atom-green`, `atom-yellow`, `atom-red`, `atom-cyan`).
- **Font:** Geist (Google Fonts CDN) for body/UI text (`font-sans`). Geist Mono (`font-mono`) reserved for terminal labels, code blocks.

## 04_ AESTHETIC DIRECTIVES (THE VIBE)
The UI is a personal control panel — operator console, not consumer SaaS.
- **Geometry:** Brutalist and sharp. `rounded-none` everywhere. Visible borders.
- **Color use:** Light backgrounds use `zinc-50/100/200` borders, `zinc-400/500` muted text, `zinc-900/white` headings. Dark uses `atom-*` equivalents.
- **Cards/rows:** `border border-zinc-200 dark:border-atom-border` with `hover:bg-zinc-50 dark:hover:bg-atom-surface transition-colors`.
- **Buttons:** No border-radius. `uppercase tracking-widest font-bold text-xs`. Primary = `bg-zinc-900 dark:bg-white text-white dark:text-zinc-900`.
- **Copywriting:** Direct, systems-oriented. No marketing fluff.

## 05_ KEY FILE MAP
```
core/
├── cmd/
│   ├── platform-migrator/main.go  # DB migration runner
│   ├── platform-server/main.go    # Core API server
│   └── platform-web/main.go       # BFF web server
├── internal/
│   ├── api/                       # Core API HTTP handlers
│   │   ├── auth.go                # provision/delete account endpoints
│   │   ├── handler.go             # handler struct + DI
│   │   └── router.go              # chi route registration
│   ├── config/config.go           # Env-based config loading
│   ├── db/                        # pgx + sqlc generated layer
│   ├── k8s/                       # Kubernetes client
│   ├── server/server.go           # Dependency wiring
│   ├── service/auth.go            # Auth service (provision user)
│   └── web/
│       ├── auth.go                # WorkOS OAuth helpers + middleware
│       ├── handler.go             # All HTTP handlers (BFF)
│       ├── router.go              # chi route registration
│       └── ui/
│           ├── components/
│           │   ├── layout.templ           # Public shell (header, footer)
│           │   └── dashboard_layout.templ # Dashboard shell (sidebar nav)
│           ├── pages/
│           │   ├── dashboard.templ
│           │   ├── project.templ
│           │   ├── account.templ
│           │   └── settings.templ
│           └── static/
│               ├── input.css      # Tailwind source
│               └── styles.css     # Compiled output
infrastructure/
├── terraform/providers/hetzner/   # Hetzner Cloud IaC
└── argocd/                        # GitOps app manifests
Taskfile.yml                       # All dev/infra tasks
```

## 06_ DEV WORKFLOW
- `task dev:web` — runs `templ generate --watch` + Tailwind watch + Air (hot reload) for the BFF.
- `task dev:server` — runs the Core API with Air.
- After editing any `.templ` file: `templ generate` (or let the watcher handle it).
- After changes: `go build ./...` from repo root to verify no compilation errors before assuming success.

## 07_ CODE GENERATION PROTOCOL
- **[MANDATORY] No Yapping:** No generic setup instructions, apologies, or filler. Provide exactly the code requested.
- **[MANDATORY] Read Before Editing:** Always read a file before modifying it. Never guess indentation — the project uses tabs.
- **[MANDATORY] Secure by Default:** Containers run as non-root. All public traffic routes through Ingress NGINX with Let's Encrypt TLS.
- **[MANDATORY] Minimal Changes:** Only change what was asked. Do not refactor adjacent code, add docstrings, or "improve" things that were not broken.
