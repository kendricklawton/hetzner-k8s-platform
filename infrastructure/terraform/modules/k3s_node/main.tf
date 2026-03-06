# Core K3s bootstrap manifests — provider-agnostic.
# Provider-specific manifests (CCM, CSI, cloud secrets) are passed in via
# extra_manifests from the provider layer. This module never needs to change
# when adding a new provider.

variable "k3s_load_balancer_ip" {
  description = "Static internal IP of the K3s API load balancer"
  type        = string
}

variable "mtu" {
  description = "Network MTU for Cilium (provider-dependent: 1450 for Hetzner, 1500 for bare metal)"
  type        = number
  default     = 1500
}

variable "cilium_version" { type = string }
variable "ingress_nginx_version" { type = string }
variable "sealed_secrets_version" { type = string }
variable "argocd_version" { type = string }
variable "git_repo_url" { type = string }

variable "extra_manifests" {
  description = "Provider-specific manifests (CCM secret, CCM, CSI, etc.) merged with core manifests"
  type        = map(string)
  default     = {}
}

locals {
  core_manifests = {
    "110-cilium.yaml" = templatefile("${path.module}/bootstrap/110-cilium.yaml", {
      MTU            = var.mtu
      CiliumVersion  = var.cilium_version
      K8sServiceHost = var.k3s_load_balancer_ip
    })
    "120-ingress-nginx.yaml" = templatefile("${path.module}/bootstrap/120-ingress-nginx.yaml", {
      IngressNginxVersion = var.ingress_nginx_version
    })
    "130-sealed-secrets.yaml" = templatefile("${path.module}/bootstrap/130-sealed-secrets.yaml", {
      SealedSecretsVersion = var.sealed_secrets_version
    })
    "140-argocd.yaml" = templatefile("${path.module}/bootstrap/140-agrocd.yaml", {
      ArgoCDVersion = var.argocd_version
    })
    "150-root-app.yaml" = templatefile("${path.module}/bootstrap/150-root-app.yaml", {
      GitRepoURL = var.git_repo_url
    })
  }

  all_manifests = merge(local.core_manifests, var.extra_manifests)
}

output "rendered_manifests" {
  description = "Complete set of manifests to inject into /var/lib/rancher/k3s/server/manifests/"
  value       = local.all_manifests
}
