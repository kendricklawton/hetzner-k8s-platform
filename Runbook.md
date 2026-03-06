# Runbook

Operational procedures for the platform. Single-operator context — this is for me.

---

## Cluster Bootstrap

### 1. Build golden images (Packer)
```sh
cd infrastructure/packer
packer build ubuntu.pkr.hcl
```
This produces a hardened Ubuntu snapshot in Hetzner. Two image types: `role=k3s-node` and `role=nat-gateway`.

### 2. Provision infrastructure (Terraform)
```sh
cd infrastructure/terraform/providers/hetzner

# Dev
terraform init -backend-config=... 
terraform apply -var-file=dev.tfvars

# Prod
terraform apply -var-file=prod.tfvars
```

Terraform creates:
- VPC + subnet
- NAT gateway server
- K3s API load balancer + ingress load balancer
- Control plane servers (1 for dev, 3 for prod) with K3s bootstrap cloud-init
- Worker nodes (1 for dev, 3 for prod)
- Bootstrap manifests injected into `/var/lib/rancher/k3s/server/manifests/` on the init server

### 3. Connect to cluster
```sh
# Via Tailscale — kubectl config is on the init server
ssh ubuntu@<tailscale-ip-of-init-server>
sudo cat /etc/rancher/k3s/k3s.yaml
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

### Seal a new secret
```sh
# Fetch the cluster public key
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system > pub-cert.pem

# Seal
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  kubeseal --cert pub-cert.pem --format yaml > my-secret-sealed.yaml
```
Commit `my-secret-sealed.yaml` to Git. Never commit the raw secret.

### Rotate a sealed secret
Re-seal with the current cluster key and push to Git. ArgoCD syncs it.

---

## Database (CNPG)

### Connect
```sh
kubectl exec -it -n postgres \
  $(kubectl get pod -n postgres -l role=primary -o name | head -1) \
  -- psql -U platform platform
```

### Manual backup trigger
```sh
kubectl annotate cluster platform-cluster \
  -n postgres \
  cnpg.io/immediateBackup=true
```

### Check backup status
```sh
kubectl get backup -n postgres
```

---

## Deployments

Applications are deployed as ArgoCD `Application` CRs pointing to Helm charts or raw manifests in this repo. To deploy a new app:

1. Add Kubernetes manifests (Deployment, Service, Ingress) under `infrastructure/argocd/manifests/apps/<app-name>/`
2. Add an ArgoCD `Application` CR under `infrastructure/argocd/apps/`
3. Push to Git — ArgoCD auto-syncs

For TLS: cert-manager issues Let's Encrypt certificates automatically when an `Ingress` resource has the `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation.

---

## Teardown

```sh
cd infrastructure/terraform/providers/hetzner
terraform destroy -var-file=dev.tfvars
```
This destroys all cloud resources. Sealed Secrets keys are lost — re-sealing all secrets is required on next bootstrap.

---

## Terraform Resource Names

Pattern: `{env}-{region}-{type}[-{role}][-{index}]`

```
dev-eu-central-nat
dev-eu-central-net
dev-eu-central-lb-api
dev-eu-central-lb-ingress
dev-eu-central-server-cp-01
dev-eu-central-server-wk-01
```

`env` and `region` are plain input variables — not derived from provider codes. This keeps the naming convention stable across providers.
