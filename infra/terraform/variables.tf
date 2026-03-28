variable "env" { type = string }               # dev | prod
variable "location" { type = string }          # Hetzner datacenter: ash, hil, nbg1, fsn1, hel1
variable "network_zone" { type = string }      # Hetzner network zone: us-east, eu-central, ap-southeast
variable "token" { sensitive = true }          # Full access — used by Terraform only
variable "token_readonly" { sensitive = true } # Read-only + volumes — injected into cluster for CCM/CSI
variable "ssh_key_name" { type = string }

# Server Types
variable "cp_server_type" { type = string }
variable "worker_server_type" { type = string }
variable "nat_gateway_type" { type = string }
variable "load_balancer_type" { type = string }
variable "git_repo_url" { type = string }

# Tailscale
variable "tailscale_api_key" { sensitive = true }
variable "tailscale_tailnet" { type = string }

# Kubernetes
variable "kubernetes_version" { type = string }
variable "cilium_version" { type = string }
variable "argocd_version" { type = string }
variable "sealed_secrets_version" { type = string }

# Hetzner cloud integration
variable "ccm_version" { type = string }
variable "csi_version" { type = string }
variable "ingress_nginx_version" { type = string }
variable "hcloud_mtu" {
  type    = number
  default = 1450
}
