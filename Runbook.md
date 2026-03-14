# Runbook

Operational procedures for the platform. Single-operator context — this is for me.

---

## Cluster Bootstrap

### 0. Set Let's Encrypt email
```sh
# Set LETS_ENCRYPT_EMAIL in .env, then:
task cluster:set-email
```
Commit the updated `cluster-issuers.yaml` to Git before deploying.

### 1. Build golden images (Packer)
```sh
task packer
```
This produces hardened Ubuntu snapshots in Hetzner. Two image types: `role=k8s-node` and `role=nat-gateway`.

### 2. Provision infrastructure (Terraform)
```sh
# Dev (Ashburn)
task plan
task apply

# Prod (Ashburn)
task plan:prod
task apply:prod
```

Terraform creates:
- VPC + subnet
- NAT gateway server
- API load balancer + ingress load balancer
- Control plane servers (1 for dev, 3 for prod) with kubeadm bootstrap cloud-init
- Worker nodes (1 for dev, 3 for prod)
- Bootstrap manifests injected via cloud-init on the init server

### 3. Connect to cluster
```sh
# Via Tailscale — kubeconfig is on the init control plane node
ssh root@<tailscale-ip-of-init-server>
cat /etc/kubernetes/admin.conf
```
Copy kubeconfig locally and replace `127.0.0.1` with the Tailscale IP of the init server.

### 4. Verify bootstrap
```sh
kubectl get nodes
kubectl get pods -A
```
ArgoCD, Cilium, ingress-nginx, cert-manager, Sealed Secrets should all be running.

---

## ArgoCD

### Access
ArgoCD is not exposed on a public ingress by default. Use port-forward:
```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080
```
Or add a Tailscale-internal ingress rule for direct access.

### Initial admin password
```sh
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

### Sync an app manually
```sh
argocd app sync <app-name>
```

---

## Sealed Secrets

### Fetch the cluster's public cert (one-time after bootstrap)
```sh
task cluster:fetch-cert
```
Saves to `keys/sealed-secrets-cert.pem`. This file is gitignored.

### Seal a new secret
```sh
task cluster:seal TENANT=observability NAME=grafana-admin-secret KEY=GF_SECURITY_ADMIN_PASSWORD VAL='my-password'
```
Output goes to `tenants/<TENANT>/<NAME>-sealed.yaml`. Copy to the appropriate manifest location and commit.

Optional: specify `DEST=infra/manifests/secrets/my-secret.yaml` to write directly to a target path.

### Rotate a sealed secret
Re-seal with the current cluster cert and push to Git. ArgoCD syncs it.

### Backup the sealing key
```sh
task backup:sealed-secrets-key
```
Exports the master key from the cluster and uploads to GCS. Run after every bootstrap or key rotation.

---

## Database (CNPG)

### Connect
```sh
kubectl exec -it -n platform-system \
  $(kubectl get pod -n platform-system -l role=primary -o name | head -1) \
  -- psql -U platform platform
```

### Manual backup trigger
```sh
kubectl annotate cluster platform-cluster \
  -n platform-system \
  cnpg.io/immediateBackup=true
```

### Check backup status
```sh
kubectl get backup -n platform-system
```

---

## Deployments

Applications are deployed as ArgoCD `Application` CRs pointing to Helm charts or raw manifests. To deploy a new app:

1. Add Kubernetes manifests under `infra/manifests/<app-name>/`
2. Add an ArgoCD `Application` CR under `infra/argocd/apps/`
3. Add the new app to `infra/argocd/envs/dev/kustomization.yaml` and `infra/argocd/envs/prod/kustomization.yaml`
4. Push to Git — ArgoCD auto-syncs

For TLS: cert-manager issues Let's Encrypt certificates automatically when an `Ingress` resource has the `cert-manager.io/cluster-issuer: letsencrypt` annotation.

---

## Teardown

```sh
# Dev
task destroy

# Prod
task destroy:prod
```
This destroys all cloud resources. Sealed Secrets keys are lost — re-sealing all secrets is required on next bootstrap.

---

## Terraform Resource Names

Pattern: `{env}-{location}-{type}[-{role}][-{index}]`

```
dev-ash-nat
dev-ash-net
dev-ash-lb-api
dev-ash-lb-ingress
dev-ash-server-cp-01
dev-ash-server-wk-01
```

`env` and `location` are plain input variables — not derived from provider codes.
