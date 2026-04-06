variable "env" {
  type        = string
  description = "Environment name. Used in resource names and ArgoCD overlay path. Values: dev | prod"
}

variable "location" {
  type        = string
  description = "Hetzner datacenter location. Values: ash (Ashburn), hil (Hillsboro), nbg1, fsn1, hel1"
}

variable "network_zone" {
  type        = string
  description = "Hetzner network zone matching the location. Values: us-east, eu-central, ap-southeast"
}

variable "token" {
  type        = string
  sensitive   = true
  description = "Hetzner API token with full read/write access. Used by Terraform only — never injected into the cluster."
}

variable "token_readonly" {
  type        = string
  sensitive   = true
  description = "Hetzner API token with read-only access + volume permissions. Injected into the cluster for CCM and CSI."
}

variable "ssh_key_name" {
  type        = string
  description = "Name of the SSH key uploaded to Hetzner Cloud (used for emergency node access via Hetzner console)."
}

variable "cp_server_type" {
  type        = string
  description = "Hetzner server type for control plane nodes. e.g. cpx21, cpx31, ccx22"
}

variable "worker_server_type" {
  type        = string
  description = "Hetzner server type for worker nodes. e.g. cpx21, cpx31, ccx22"
}

variable "nat_gateway_type" {
  type        = string
  description = "Hetzner server type for NAT gateway VM(s). A small type is fine — cpx11 handles typical workloads."
}

variable "load_balancer_type" {
  type        = string
  description = "Hetzner load balancer type. e.g. lb11, lb21"
}

variable "git_repo_url" {
  type        = string
  description = "HTTPS URL of this Git repository. ArgoCD uses this to sync the platform apps."
}

variable "tailscale_api_key" {
  type        = string
  sensitive   = true
  description = "Tailscale API key used to generate pre-auth keys for node enrollment. Scoped to the tailnet."
}

variable "tailscale_tailnet" {
  type        = string
  description = "Tailscale tailnet name (e.g. example.com or your-org.github). Nodes join this tailnet."
}

variable "kubernetes_version" {
  type        = string
  description = "Full Kubernetes version to install via kubeadm. e.g. v1.32.13"
}

variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version. Installed during cloud-init bootstrap before ArgoCD is available."
}

variable "argocd_version" {
  type        = string
  description = "ArgoCD Helm chart version. Installed during cloud-init bootstrap and manages all subsequent apps."
}

variable "sealed_secrets_version" {
  type        = string
  description = "Sealed Secrets Helm chart version. Installed during bootstrap so ArgoCD can sync encrypted secrets on first run."
}

variable "ccm_version" {
  type        = string
  description = "Hetzner Cloud Controller Manager Helm chart version. Registers per-node pod CIDR routes in the Hetzner VPC."
}

variable "csi_version" {
  type        = string
  description = "Hetzner CSI driver Helm chart version. Provides the StorageClass for PersistentVolumes backed by Hetzner volumes."
}

variable "hcloud_mtu" {
  type        = number
  default     = 1450
  description = "MTU for Hetzner private network interfaces. Hetzner's private network uses 1450 bytes. Cilium is configured with this value."
}
