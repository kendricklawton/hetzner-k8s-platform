# Runbook

Operational procedures for provisioning, deploying, and operating the project-platform infrastructure.

> See [README.md](./README.md) for stack overview and local dev setup.
> See [K8s.md](./K8s.md) for kubectl/ArgoCD/Cilium/CNPG command reference.
> See [POSTGRES.md](./POSTGRES.md) for PostgreSQL and CNPG command reference.

---

## Security Rules

- Never commit secrets, private keys, or service account JSON to the repository.
- Use `.env` (gitignored) for local development credentials.
- Use Sealed Secrets for all in-cluster secrets.
- GCS service account JSON for Terraform remote state lives in `keys/` (gitignored).

---

## Preflight Checklist

Before any provisioning or deployment operation, verify:

```bash
task --version
terraform --version
kubectl version --client
packer --version
buf --version
go version
kubeseal --version
tailscale version
```

> ArgoCD runs on the cluster — no local CLI install needed. Interact via port-forward or the UI (see section C).

Verify `.env` is populated:
- `HIVELOCITY_API_KEY`
- `WORKOS_CLIENT_ID`, `WORKOS_CLIENT_SECRET`
- `DATABASE_URL`
- GCS credentials path for Terraform backend

---

## Cluster Access via Tailscale

The K3s API server listens on the node's **Tailscale IP** (not the public IP). kubectl will not reach the cluster unless Tailscale is connected on your machine.

### 1. Connect Tailscale

```bash
tailscale up
tailscale status          # confirm the control plane node appears and is online
tailscale ping <node-tailscale-hostname>   # verify reachability
```

### 2. Fetch the kubeconfig

`task hv:kubeconfig` pulls the kubeconfig from the cluster and merges it into `~/.kube/config`. Terraform patches the `server:` address to the Tailscale IP of the control plane node automatically.

```bash
task hv:kubeconfig     # fetch + merge for Hivelocity cluster
```

### 3. Verify kubectl is pointing at the right cluster

```bash
kubectl config current-context      # confirm context name
kubectl config get-contexts         # list all contexts
kubectl cluster-info                # should show the Tailscale IP, not 127.0.0.1
kubectl get nodes -o wide           # nodes should appear
```

### If kubectl times out

The most common causes:
1. **Tailscale is not connected** — run `tailscale up` and retry.
2. **Wrong server address in kubeconfig** — the `server:` field must be the Tailscale IP, not a public or internal IP. Check with:
   ```bash
   kubectl config view --minify | grep server
   # Should be: https://<tailscale-ip>:6443
   ```
   If it shows the wrong address, re-run `task hv:kubeconfig` or patch it manually:
   ```bash
   kubectl config set-cluster <cluster-name> --server=https://<tailscale-ip>:6443
   ```
3. **Wrong context active** — run `kubectl config use-context <correct-context>`.
4. **Node is down** — check Hivelocity console or Terraform state.

---

## A. Build Golden Images (Packer)

Packer images bake in K3s, gVisor (`runsc`), and Tailscale. Images are used as the base for all Terraform-provisioned nodes.

```bash
task packer:hv:k3s     # Hivelocity — K3s node image
task packer:hv:nat     # Hivelocity — NAT gateway image
```

After a build, update the Terraform variable that references the image ID before provisioning new nodes.

---

## B. Infrastructure Provisioning (Terraform)

Terraform state is stored remotely in GCS. Provider: Hivelocity (Dallas hub).

### Hivelocity

```bash
task hv:plan           # preview changes
task hv:apply          # provision / update infrastructure
task hv:output         # show Terraform outputs (IPs, Floating IP, etc.)
task hv:kubeconfig     # fetch and merge kubeconfig for the cluster
task hv:destroy        # DESTRUCTIVE — tears down all Hivelocity resources
```

After `hv:apply`, Terraform bootstraps the cluster by applying manifests from `infrastructure/terraform/modules/k3s_node/bootstrap/`. This installs ArgoCD and registers the root App of Apps. All subsequent platform component management is handled by ArgoCD.

### Floating IP (Edge Router)

The Floating IP is provisioned alongside the cluster and mapped to the primary bare-metal node. It uses Hivelocity's 20 TB unmetered bandwidth pool — no per-GB egress billing.

```bash
# Reassign Floating IP to a different node (failover)
task hv:floating-ip-reassign NODE=<target-node-id>
```

---

## C. GitOps — ArgoCD

ArgoCD runs on the cluster and watches this repo. There is no local ArgoCD CLI install. All deployments happen via Git — push to `main` and ArgoCD picks it up.

All platform component manifests live under `infrastructure/argocd`. Do not `kubectl apply` directly for anything ArgoCD manages.

### Normal workflow

```
1. Edit manifests in infrastructure/argocd
2. Commit and push to main
3. ArgoCD auto-syncs — done
```

### Check sync status (via kubectl)

```bash
# ArgoCD app resources
kubectl get applications -n argocd
kubectl describe application <app-name> -n argocd

# ArgoCD pods healthy
kubectl get pods -n argocd

# Events (shows sync errors)
kubectl get events -n argocd --sort-by='.lastTimestamp'
```

### Access ArgoCD UI (port-forward to cluster)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Admin password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

If you have the `argocd` CLI installed locally (optional):

```bash
argocd login localhost:8080 --insecure --username admin --password <password>
argocd app list
argocd app sync <app-name>
argocd app diff <app-name>
argocd app rollback <app-name> <revision>
```

---

## D. Sealed Secrets

All in-cluster secrets must be sealed before committing to Git.

```bash
# Fetch the controller public cert (do this once per cluster, store cert locally)
kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller > pub-cert.pem

# Create and seal a secret
kubectl create secret generic <name> \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem -o yaml > sealed-<name>.yaml

# Or use the Taskfile shortcut (SSHs into cluster, runs kubeseal remotely)
task cluster:seal TENANT=<ns> NAME=<secret> KEY=<k> VAL=<v>
```

Sealed secrets are safe to commit — they can only be decrypted by the sealed-secrets controller inside the cluster.

---

## E. Platform Deployments

All platform services are deployed via ArgoCD. Typical deployment flow:

```
1. Build + push image (CI/CD or manual)
2. Update image tag in infrastructure/argocd/<service>/deployment.yaml
3. Commit and push to main
4. ArgoCD detects diff and syncs within ~3 minutes
5. Verify: kubectl rollout status deployment/<name> -n <ns>
```

For emergency rollback:

```bash
argocd app rollback <app-name> <revision>
# or
kubectl rollout undo deployment/<name> -n <ns>
```

---

## F. Observability

```bash
# VictoriaMetrics
kubectl port-forward svc/victoria-metrics -n monitoring 8428:8428
# Open http://localhost:8428

# Grafana
kubectl port-forward svc/grafana -n monitoring 3000:3000
# Open http://localhost:3000 (admin / check sealed secret for password)

# Loki (query via Grafana — no direct UI)
kubectl logs -n monitoring -l app=loki --tail=50

# Fluent Bit (log shipper)
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit --tail=50
```

---

## G. Database Operations (CNPG)

See [POSTGRES.md](./POSTGRES.md) for full PostgreSQL and CNPG command reference.

Quick cluster health check:

```bash
kubectl get cluster -n database
kubectl describe cluster platform-db -n database
kubectl get pods -n database
```

---

> Do not commit secrets, private keys, or service account JSON files. Use `.env` for local dev (gitignored). Use Sealed Secrets for in-cluster secrets.
