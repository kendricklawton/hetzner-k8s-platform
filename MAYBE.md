# Maybe

Ideas to explore later.

## Rust-based developer portal (Backstage alternative)

Backstage is TypeScript/React with 200+ plugins. No Rust alternative exists. The core app is simple — the moat is the plugin ecosystem.

### Why it would win
- Single binary, no runtime, 10x less memory than Node.js
- Sub-second startup, instant page loads
- No npm supply chain risk
- Deploy as a static pod — no database needed if it reads from K8s directly
- "Same portal experience, runs on a Raspberry Pi, zero maintenance"

### Why WASM plugin compat is hard
Backstage plugins are React components that import Node.js modules, use Express middleware, and talk to PostgreSQL. Can't just compile them to WASM. You'd need:
- A WASM runtime that exposes the same Backstage plugin API
- A compatibility layer translating Express-based backend plugins
- A React-compatible frontend renderer (or rewrite the UI)
- Essentially reimplementing Node.js standard library in WASM

### Realistic path
Skip WASM compat. Build a Rust portal with its own simple plugin API, then write the 10 plugins that 90% of teams actually use:
- Kubernetes (pod status, logs)
- ArgoCD (deployment status, sync)
- Grafana (embedded dashboards)
- GitHub (repos, PRs, CI status)
- PagerDuty (on-call, incidents)
- Software catalog (service ownership, dependencies)
- Software templates (scaffold new services)
- TechDocs (render markdown docs)
- Search (unified across all plugins)
- Auth (SSO, RBAC)

### Tech stack: Leptos
- **Leptos** — full-stack Rust framework, SSR + WASM frontend
- **Axum** — backend HTTP server (async, tower-based)
- **SQLx** — async database driver (PostgreSQL or SQLite for lightweight mode)
- **Plugin system** — Rust traits (`PortalPlugin`), loaded as dynamic libraries or WASM modules
- Single `cargo build` produces the entire app — backend, frontend, WASM — one binary

This is a startup-sized project, not a side project.
