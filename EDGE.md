# Edge Cases — Hetzner K8s Platform

Status legend: 📋 Planned | 🔧 Infra-only (no code needed yet) | ⚠️ Monitor | ✅ Done

---

## Bootstrap & Provisioning

*Race conditions, ordering failures, and partial-bootstrap states during cluster bring-up.*

---

### ✅ NAT Gateway Single Point of Failure

**Problem:** Only one NAT gateway exists. If it crashes, kernel panics, or Hetzner reschedules it, every K8s node loses internet simultaneously. Helm installs fail, image pulls fail, DNS resolution fails. The `time_sleep` wait (60s) before creating the default route has no health check — if cloud-init takes longer than 60s, nodes boot before the NAT is ready.

**Fix (done):** Environment-aware NAT redundancy via `cluster_config.nat_count`. Dev gets 1 NAT (cost saving), prod gets 2. The primary NAT (`nat_primary_ip = 10.0.1.2`) holds the network route. The secondary NAT (`nat_secondary_ip = 10.0.1.3`) runs an identical iptables/Tailscale setup plus a `nat-failover.service` systemd watchdog. The watchdog pings the primary every 10s; after 3 consecutive failures (30s), it uses the Hetzner API to delete the old route and add a new `0.0.0.0/0` route pointing to itself. Failover is one-directional — `terraform apply` restores the primary route when the primary is repaired. The secondary receives `var.token` and `hcloud_network.main.id` via cloud-init for API access.

**Where:** `infra/terraform/main.tf` — `hcloud_server.nat` (primary), `hcloud_server.nat_secondary` (count-gated), `locals.nat_primary_ip`/`nat_secondary_ip`, `cluster_config.nat_count`. `infra/terraform/templates/cloud-init-nat.yaml` — `is_primary` conditional, failover script + systemd unit.

---

### ✅ NAT Iptables Rules Lost on Reboot

**Problem:** `cloud-init-nat.yaml` runs `netfilter-persistent save` but doesn't validate success. If `/etc/iptables/rules.v4` doesn't exist (package not installed in Packer image), the save fails silently. After a reboot, iptables resets to defaults. All K8s nodes lose internet.

**Fix (done):** Two layers. (1) Packer NAT build already installs `iptables-persistent` with debconf pre-seeding for autosave. (2) Cloud-init now validates the save succeeded: `test -s /etc/iptables/rules.v4` after `netfilter-persistent save`. If the file is empty or missing, cloud-init logs `[FATAL]` and exits non-zero — failing the NAT setup loudly instead of silently.

**Where:** `infra/terraform/templates/cloud-init-nat.yaml` — iptables block (post-save validation). `infra/packer/ubuntu.pkr.hcl` — line 139, `iptables-persistent` already in package list.

---

### ✅ API Load Balancer Has No Health Check

**Problem:** The Kubernetes API load balancer (`hcloud_load_balancer.api`) has a TCP service on port 6443 but no `health_check` block. The LB blindly routes to all attached servers. If a control-plane node is down or kubelet is crashed, traffic is still routed to it. `kubeadm join` commands hang with no error.

**Fix (done):** Added TCP health check to `hcloud_load_balancer_service.k8s_api` — checks port 6443 every 10s, 5s timeout, 3 retries before marking a target unhealthy. Dead control-plane nodes are automatically removed from rotation.

**Where:** `infra/terraform/main.tf` — `hcloud_load_balancer_service.k8s_api`.

---

### ✅ Hetzner Metadata Service Unreachable — No Provider-ID

**Problem:** Cloud-init polls `169.254.169.254` for 60s to get the Hetzner instance ID. If the metadata service is slow or the metadata route isn't installed yet, `HCLOUD_ID` is empty. The `provider-id` kubelet arg is set to `hcloud://` (no ID). Hetzner CCM and CSI cannot identify which node owns which volume. PVC provisioning silently fails.

**Fix (done):** Bootstrap script now exits non-zero if `HCLOUD_ID` is empty after the 30-retry loop. Logs `[FATAL] Cannot proceed without Hetzner instance ID — CCM/CSI will fail` and halts bootstrap instead of continuing with a broken provider-id.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — metadata wait loop, hard exit after retry exhaustion.

---

### ✅ Kubeadm Config Patching via Sed Is Fragile

**Problem:** The bootstrap script uses `sed -i` to append the Tailscale IP to `certSANs` and inject `provider-id` into kubelet extra-args. This is brittle YAML manipulation — any change to indentation, comments, or structure in the kubeadm config causes sed to silently do nothing. The resulting cert has no Tailscale SAN, and nodes have no provider-id.

**Fix (done):** Replaced structural YAML manipulation with deterministic placeholder substitution. The static kubeadm config now contains `__TAILSCALE_IP__` in certSANs and `__HCLOUD_PROVIDER_ID__` in kubeletExtraArgs. The bootstrap script does simple `sed -i "s|__PLACEHOLDER__|$VALUE|"` — no YAML-aware appending, no multi-line injection, no duplicate config blocks. If Tailscale IP is unavailable, the placeholder line is deleted with `sed -i "/__TAILSCALE_IP__/d"`. Both cp_init and cp_join paths use the same pattern.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — static kubeadm config (placeholder entries), cp_init and cp_join bootstrap sections (placeholder replacement).

---

### ✅ Helm Repo Unreachable During Bootstrap

**Problem:** The init bootstrap script runs `helm repo add` + `helm install` for Cilium, CCM, CSI, Sealed Secrets, and ArgoCD in sequence. If any helm repo is unreachable (DNS failure, rate limit, network partition), the command fails and the entire bootstrap aborts. There's no retry logic around individual helm installs.

**Fix:** Added `helm_retry` helper function (5 attempts, 15s backoff) wrapping every `helm repo add` and `helm install` call. Fatal exit after exhausting retries.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — `helm_retry()` function + all helm calls wrapped.

---

### ✅ Worker Nodes Don't Verify Ready Status

**Problem:** Worker bootstrap sleeps 15s after `kubeadm join`, checks if `systemctl is-active kubelet` is true, and declares success. But kubelet can be "active" while the node is `NotReady` (CNI not configured, image pull failures, resource pressure). Workloads scheduled immediately will fail.

**Fix:** Two-phase verification: first wait for kubelet service to be active (60s timeout), then poll the API server using the bootstrap token to check the node's `Ready` condition (5min timeout, 5s interval). Hard exit on failure with kubelet journal tail.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — worker final verification block.

---

## Network & Routing

*Cilium, MTU, firewall, and traffic path edge cases.*

---

### ✅ Cilium Native Routing Without Host Routes

**Problem:** Cilium is configured with `routingMode=native` and `autoDirectNodeRoutes=false`. Native routing requires the underlying network to know how to route pod CIDR traffic between nodes. On Hetzner Cloud, this works because Hetzner CCM advertises routes — but only after CCM is installed. Between Cilium install and CCM install, cross-node pod traffic is black-holed.

**Fix:** Mitigated by existing design: (1) the init node has no cross-node traffic during bootstrap, (2) `cloud-provider=external` in kubelet args sets the `node.cloudprovider.kubernetes.io/uninitialized` taint which blocks workload scheduling until CCM removes it, (3) join nodes arrive after CCM is already running. Added documentation comment in bootstrap script explaining the ordering safety.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — Cilium install step comment.

---

### ✅ Firewall Rules Are Not Role-Specific

**Problem:** A single firewall (`hcloud_firewall.cluster_fw`) is applied to all nodes via `label_selector = "cluster=${local.prefix}"`. NAT gateway, control-plane, and worker nodes all get identical rules. The NAT doesn't need Tailscale ports. Workers don't need etcd peer port (2380). Overly broad rules weaken defense-in-depth.

**Fix:** Split into 3 role-specific firewalls: `fw-nat` (internal + Tailscale, no HTTP), `fw-cp` (API 6443, etcd 2379-2380, Tailscale), `fw-worker` (HTTP/HTTPS, NodePort 30000-32767, Tailscale). Applied via `cluster=<prefix>,role=<role>` label selectors. Added `role` labels to all server resources.

**Where:** `infra/terraform/firewall.tf` — 3 firewalls. `infra/terraform/main.tf` — server labels.

---

### ✅ MTU Mismatch Between Hetzner and Cilium

**Problem:** `hcloud_mtu` defaults to 1450 and is passed to Cilium. If the actual Hetzner Cloud network MTU is different (Hetzner uses 1450 for VXLAN overlay networks), PMTUD may not work correctly. Oversized packets are silently fragmented or dropped, causing intermittent timeouts on large payloads (file uploads, database dumps).

**Fix:** Added runtime MTU validation in the bootstrap script before Cilium install. Reads the actual interface MTU via `ip link show` and compares against the configured `hcloud_mtu`. Logs a warning if they diverge.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — MTU check before Cilium install step.

---

## Backups & Disaster Recovery

*GCS bucket gaps, etcd recovery, and backup integrity.*

---

### ✅ GCS Backup Buckets Have No Versioning

**Problem:** Backup buckets are created with `uniform_bucket_level_access = true` but no `versioning { enabled = true }`. If a backup file is overwritten or deleted (ransomware, operator error, rclone sync deleting source-deleted files), there's no recovery point. Lifecycle rules eventually delete everything.

**Fix:** Enable versioning on all backup buckets:
```hcl
versioning {
  enabled = true
}
```
Add a lifecycle rule to clean up non-current versions after 30 days to control costs.

**Where:** `infra/terraform/backups.tf` — all `google_storage_bucket` resources.

---

### ✅ RustFS Backup Uses Destructive `rclone sync`

**Problem:** `410-rustfs-gcs-backup.yaml` uses `rclone sync` which makes the destination an exact mirror of the source. If files are deleted from RustFS (ransomware, accidental `mc rm`), the next sync run deletes them from the GCS "backup" too. This is a mirror, not a backup.

**Fix:** Change `rclone sync` to `rclone copy` (additive only — never deletes from destination). Rely on GCS lifecycle rules to expire old objects. Alternatively, enable GCS bucket versioning so `sync`-deleted objects are retained as non-current versions.

**Where:** `infra/argocd/apps/410-rustfs-gcs-backup.yaml` — rclone command.

---

### ✅ etcd Backups Are Local Only — Not Synced to GCS

**Problem:** The etcd backup CronJob writes snapshots to a 5Gi PVC on a control-plane node. If the node dies, the PVC is stuck on a dead volume. The GCS `etcd-backups` bucket exists but nothing uploads to it. Backups are not actually off-cluster.

**Fix:** Add a `gsutil cp` or `rclone copy` step to the etcd backup CronJob that uploads each snapshot to the GCS etcd bucket after the local write succeeds. Mount the GCS service account secret into the CronJob pod.

**Where:** `infra/argocd/apps/400-etcd-backup.yaml` — CronJob script. `infra/terraform/backups.tf` — `google_storage_bucket.etcd_backups` (bucket exists, just unused).

---

### ✅ GCS Service Account Key Has No Rotation

**Problem:** `google_service_account_key.backup` creates a static key with no expiration. If leaked, the attacker has permanent write access to all backup buckets. No alerting or rotation schedule exists.

**Fix:** Use Workload Identity Federation instead of long-lived SA keys. If WIF isn't feasible (cluster isn't on GKE), implement a rotation CronJob that creates a new key via the GCP API, updates the Kubernetes secret, and deletes the old key. At minimum, add a calendar reminder for manual rotation every 90 days.

**Where:** `infra/terraform/backups.tf` — `google_service_account_key.backup`.

---

### ✅ No Backup Restoration Testing

**Problem:** Backups are created (etcd snapshots, RustFS sync, Postgres via CNPG) but never tested by actually restoring them. A backup that can't be restored is not a backup. Corruption, missing permissions, or schema drift are only discovered during a real disaster.

**Fix:** Add a periodic (monthly) restore-test CronJob or runbook: restore etcd snapshot to a temporary data-dir, verify integrity with `etcdutl snapshot status`. For Postgres, restore CNPG backup to a throwaway cluster. Document in EDGE.md when last tested.

**Where:** New CronJob or Taskfile target. `infra/argocd/apps/400-etcd-backup.yaml` — add restore-test job.

---

## Security & Secrets

*Key rotation, credential exposure, and hardening gaps.*

---

### ✅ Sealed Secrets Key Not Backed Up

**Problem:** The Sealed Secrets controller generates a sealing key pair on first boot. This key is stored only in the `sealed-secrets-key` secret in `kube-system`. If etcd is lost and restored from a backup taken before the key was generated — or if the cluster is rebuilt from scratch — all existing SealedSecret objects become permanently undecryptable.

**Fix:** After initial bootstrap, export the sealing key: `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master.key`. Store it encrypted in GCS or a password manager. Document the recovery procedure.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — post-bootstrap. Manual runbook step.

---

### ✅ Alertmanager Config Is a Plain Secret (Not Sealed)

**Problem:** `315-alertmanager-config.yaml` is a plain Kubernetes `Secret` committed to Git. Currently contains placeholder webhook URLs, but when real endpoints are added (Discord webhooks, PagerDuty keys), those credentials are stored in plaintext in both Git and etcd.

**Fix:** Convert to a `SealedSecret` before adding real webhook URLs. The plaintext placeholder version is fine for bootstrapping, but must be sealed before production use.

**Where:** `infra/argocd/apps/315-alertmanager-config.yaml`.

---

### ✅ RustFS Credentials in Plaintext ArgoCD App

**Problem:** `240-rustfs.yaml` has `rootPassword: "your-secure-rustfs-password"` in the helm values. Even as a placeholder, this pattern encourages setting the real password directly in the YAML. Git history retains it permanently.

**Fix:** Remove the password from the ArgoCD app. Use `existingSecret` in the helm values to reference a SealedSecret instead:
```yaml
existingSecret: rustfs-credentials
```

**Where:** `infra/argocd/apps/240-rustfs.yaml` — helm values.

---

### ✅ Hetzner Token Stored in Cluster Secret

**Problem:** The Hetzner API token is injected into the cluster via `hcloud-secret.yaml` (written by cloud-init, applied by bootstrap script). This token has full API access — it can create, delete, and modify any Hetzner resource. If an attacker gains access to `kube-system` secrets, they own the entire Hetzner account.

**Fix:** Create a read-only Hetzner API token for CCM/CSI (Hetzner supports token scoping). The bootstrap token needs write access, but the long-lived in-cluster token should be read-only + volume management only.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — hcloud-secret.yaml. `infra/terraform/main.tf` — consider separate `var.hcloud_readonly_token`.

---

## Observability

*Monitoring blind spots, storage exhaustion, and silent failures.*

---

### ✅ Alertmanager Webhook URLs Are Placeholders

**Problem:** `315-alertmanager-config.yaml` routes all alerts to `http://placeholder.local/alert`. If deployed without updating, every alert is silently dropped. The cluster can be on fire with zero notification to the operator.

**Fix:** Replace placeholder URLs with real endpoints before first deploy. Options: Discord webhook, Telegram bot, email via SMTP relay, or a dead man's switch service (Healthchecks.io, Cronitor). Seal the secret after adding real credentials.

**Where:** `infra/argocd/apps/315-alertmanager-config.yaml` — receivers block.

---

### ✅ No VMAlert Rules Defined

**Problem:** `vmalert` is enabled with 30s evaluation interval, but no alerting rules are defined. Without rules, vmalert evaluates nothing. Alertmanager sits idle. The entire alerting pipeline is wired up but empty.

**Fix:** Add a `VMRule` resource with baseline alerts: node not ready, pod crash looping, PVC >80% full, certificate expiring <14 days, etcd backup job failed, high memory pressure. Deploy via ArgoCD as a separate manifest.

**Where:** New file: `infra/argocd/apps/321-vm-alert-rules.yaml`.

---

### ✅ Loki Storage Exhaustion (10Gi PVC, No Alert)

**Problem:** Loki runs as a single binary with 10Gi filesystem storage. No alert fires when disk usage crosses 80%. When the PVC fills, Loki rejects new logs silently. Fluent Bit buffers fill and starts dropping logs. An incident happening during this window has no log trail.

**Fix:** Add a VMAlert rule for PVC usage: `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.8`. Consider increasing Loki PVC size or switching to GCS-backed storage for durability.

**Where:** `infra/argocd/apps/310-loki.yaml` — PVC size. New alert rule in `321-vm-alert-rules.yaml`.

---

### ✅ Grafana Admin Password Not Provisioned

**Problem:** `330-grafana.yaml` sets `adminPassword: ""` and references `envFromSecret: grafana-admin-secret`. If this secret doesn't exist, the Grafana chart generates a random password. The operator can't log in without exec'ing into the pod to retrieve it.

**Fix:** Created placeholder `grafana-admin-secret` Secret deployed at sync-wave 3 (before Grafana at wave 4). Contains `GF_SECURITY_ADMIN_PASSWORD: changeme`. Must be replaced with a SealedSecret via `task cluster:seal` before production use.

**Where:** `infra/argocd/apps/329-grafana-secret.yaml` + `infra/manifests/secrets/grafana-admin-secret.yaml`.

---

### ✅ CNPG Metrics Depend on Pod Label Selector

**Problem:** `325-cnpg-metrics.yaml` uses `selector.matchLabels: cnpg.io/podRole: instance` to discover Postgres pods. If CNPG changes this label in a future version, the VMServiceScrape stops matching. Metrics silently disappear from Grafana. No alert fires because the absence of metrics doesn't trigger anything.

**Fix:** Added `CNPGMetricsAbsent` VMRule alert: `absent(cnpg_pg_stat_activity_count)` fires after 5m with severity warning. Deployed via new ArgoCD app `321-vm-alert-rules.yaml` sourcing from `infra/manifests/alerts/`.

**Where:** `infra/argocd/apps/321-vm-alert-rules.yaml` + `infra/manifests/alerts/cnpg-absent.yaml`.

---

## ArgoCD & GitOps

*Sync ordering, missing resources, and deployment gaps.*

---

### ✅ No ClusterIssuer for cert-manager

**Problem:** `210-cert-manager.yaml` installs cert-manager but no `ClusterIssuer` is defined for Let's Encrypt. Ingress resources with `cert-manager.io/cluster-issuer: letsencrypt` annotations wait forever for certificate provisioning. TLS never activates.

**Fix:** Created both `letsencrypt-staging` and `letsencrypt` ClusterIssuers using HTTP-01 solver via nginx ingress class. Deployed at sync-wave 2 (after cert-manager CRDs are installed). Email must be updated from placeholder before production use.

**Where:** `infra/argocd/apps/211-cluster-issuer.yaml` + `infra/manifests/cert-manager/cluster-issuers.yaml`.

---

### ✅ No Pod Disruption Budgets for System Components

**Problem:** Loki, VictoriaMetrics, Grafana, and ingress-nginx have no `PodDisruptionBudget`. During `kubectl drain` (node maintenance, upgrade), all replicas of a single-replica component can be evicted simultaneously. Observability and ingress go down during maintenance windows.

**Fix:** Created PDBs with `minAvailable: 1` for ingress-nginx-controller (kube-system), Loki, VictoriaMetrics vmsingle, and Grafana (observability). Managed via ArgoCD Application sourcing from `infra/manifests/pdbs/`.

**Where:** `infra/argocd/apps/216-pod-disruption-budgets.yaml` + `infra/manifests/pdbs/{ingress-nginx,loki,victoria-metrics,grafana}.yaml`.

---

### ✅ ArgoCD Root App Path Must Match Repo Structure

**Problem:** The root ArgoCD Application points to `path: infra/argocd/apps`. If the directory is renamed or moved, ArgoCD loses sync and all managed resources drift. The root app itself is applied by cloud-init and not managed by ArgoCD — it's the one resource that can't self-heal.

**Fix:** Added a CRITICAL comment block in `cloud-init-node.yaml` above the root-app.yaml write_file documenting the coupling and the requirement to update the path if the directory is renamed.

**Where:** `infra/terraform/templates/cloud-init-node.yaml` — root-app.yaml content.

---

## Terraform State & Lifecycle

*State protection, resource safety, and operational guardrails.*

---

### ✅ No Lifecycle Protection on Critical Resources

**Problem:** No `lifecycle { prevent_destroy = true }` on the NAT gateway, network, load balancers, or control-plane init server. A `terraform destroy` or accidental `-target` removal of any of these resources causes catastrophic cluster failure. The NAT gateway deletion instantly cuts all nodes from the internet.

**Fix:** Added `prevent_destroy = true` to: `hcloud_network.main`, `hcloud_server.nat`, `hcloud_load_balancer.api`, `hcloud_load_balancer.ingress`, `hcloud_server.control_plane_init`. Added `ignore_changes = [user_data]` to all server resources (nat, cp_init, cp_join, worker) to prevent recreation on template changes.

**Where:** `infra/terraform/main.tf` — all critical resource blocks.

---

### ✅ GCS State Backend Has No Locking Verification

**Problem:** `backend "gcs" {}` is configured but GCS state locking depends on the bucket having object versioning enabled. If versioning is disabled on the state bucket, concurrent `terraform apply` runs can corrupt state.

**Fix:** Added `task infra:bootstrap` — creates the GCS state bucket with `--versioning` enabled. Idempotent (skips if bucket exists, always enforces versioning). Run once per environment before first `terraform init`.

**Where:** `Taskfile.yml` — `infra:bootstrap` task.

---

## Packer & Golden Images

*Supply chain, binary verification, and image hygiene.*

---

### ✅ Downloaded Binaries Not Signature-Verified

**Problem:** The Packer build downloads Tailscale, Helm, gVisor, and Kubernetes binaries from the internet via `curl`. Most downloads have no checksum or signature verification. A MITM attack during the Packer build injects a backdoored binary into every node's golden image.

**Fix:** crictl now downloads and verifies `.sha256` checksums. Helm install uses `VERIFY_CHECKSUM=true` (built-in SHA256 verification). All `curl | sh` calls use `--proto =https` to prevent protocol downgrade. gVisor already verified SHA512. Kubernetes installed via GPG-signed apt repo.

**Where:** `infra/packer/ubuntu.pkr.hcl` — crictl + Helm steps. `infra/packer/scripts/tailscale.sh` — HTTPS enforcement.

---

### ✅ Helm Installed from Unstable Main Branch

**Problem:** `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash` downloads from `main`, not a tagged release. A broken commit to `main` breaks the install script. The Packer build fails or installs a broken Helm.

**Fix:** Pinned to `v3.17.0` release tag: `curl https://raw.githubusercontent.com/helm/helm/v3.17.0/scripts/get-helm-3 | bash`.

**Where:** `infra/packer/ubuntu.pkr.hcl` — Helm install step.

---

### ✅ NAT and K8s Node Images Share No Base (No DRY)

**Problem:** Packer builds NAT and K8s node images as separate builds with overlapping provisioner steps (apt updates, Tailscale install, sysctl tuning). A security patch to a shared dependency must be applied in two places. Easy to miss one.

**Fix:** Extracted 3 shared scripts into `infra/packer/scripts/`: `base.sh` (apt update/upgrade, common packages, SSH hardening), `tailscale.sh` (install + state cleanup), `cleanup.sh` (apt clean, SSH host keys, cloud-init reset). Both builds reference them via `provisioner "shell" { script = ... }`.

**Where:** `infra/packer/ubuntu.pkr.hcl` + `infra/packer/scripts/{base,tailscale,cleanup}.sh`.

---

### ✅ SSH Host Keys Not Reset in Golden Image

**Problem:** The Packer build doesn't explicitly remove SSH host keys from the golden image. If `cloud-init` fails to regenerate them on first boot, all nodes created from the same image share identical SSH host keys. An attacker who compromises one node's host key can impersonate any other node.

**Fix:** Added `rm -f /etc/ssh/ssh_host_*` to both NAT and K8s cleanup provisioners in Packer. Added `ssh_deletekeys: true` and `ssh_genkeytypes: [rsa, ecdsa, ed25519]` to both cloud-init templates.

**Where:** `infra/packer/ubuntu.pkr.hcl` — both cleanup provisioners. `infra/terraform/templates/cloud-init-node.yaml` + `cloud-init-nat.yaml` — header.
