terraform {
  required_version = ">= 1.5.0"
  backend "gcs" {}
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5.1"
    }
  }
}

# VARIABLES
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

provider "hcloud" {
  token = var.token
}

# GCP — backup buckets live beside the Terraform state bucket
variable "gcp_project" { type = string }
variable "gcp_region" {
  type    = string
  default = "us-central1"
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_tailnet
}

locals {
  # {env}-{location} — both are plain input variables.
  # Pattern: {env}-{location}-{type}[-{role}][-{index}]
  # Examples: dev-ash-server-cp-01, prod-ash-lb-api
  prefix = "${var.env}-${var.location}"

  # Infrastructure IPs
  nat_primary_ip           = cidrhost("10.0.1.0/24", 2)
  nat_secondary_ip         = cidrhost("10.0.1.0/24", 3)
  api_load_balancer_ip     = cidrhost("10.0.1.0/24", 11)
  ingress_load_balancer_ip = cidrhost("10.0.1.0/24", 12)

  # Cluster size per environment
  cluster_config = {
    dev  = { cp_count = 1, worker_count = 1, nat_count = 1 }
    prod = { cp_count = 3, worker_count = 3, nat_count = 2 }
  }

  # Sticky name→IP maps for the recycle method
  cp_map = {
    for i in range(local.cluster_config[var.env].cp_count) :
    format("${local.prefix}-server-cp-%02d", i + 1) => cidrhost("10.0.1.0/24", i + 21)
  }

  worker_map = {
    for i in range(local.cluster_config[var.env].worker_count) :
    format("${local.prefix}-server-wk-%02d", i + 1) => cidrhost("10.0.1.0/24", i + 31)
  }

  # Split init control plane from join control planes
  init_cp_name = format("${local.prefix}-server-cp-%02d", 1)
  join_cps     = { for k, v in local.cp_map : k => v if k != local.init_cp_name }

  # kubeadm bootstrap token: [a-z0-9]{6}.[a-z0-9]{16}
  kubeadm_token = "${random_string.kubeadm_token_id.result}.${random_string.kubeadm_token_secret.result}"
}

# --- KUBEADM TOKENS ---
resource "random_string" "kubeadm_token_id" {
  length  = 6
  upper   = false
  special = false
}

resource "random_string" "kubeadm_token_secret" {
  length  = 16
  upper   = false
  special = false
}

# Certificate key for HA control-plane join (32-byte hex)
resource "random_id" "kubeadm_cert_key" {
  byte_length = 32
}

# Encryption key for encrypting Secrets at rest in etcd (32-byte base64)
resource "random_id" "encryption_key" {
  byte_length = 32
}

# --- TAILSCALE PRE-AUTH KEYS ---
resource "tailscale_tailnet_key" "nat" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  description   = "${local.prefix}-nat"
}

resource "tailscale_tailnet_key" "cp" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  description   = "${local.prefix}-cp"
}

resource "tailscale_tailnet_key" "worker" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  description   = "${local.prefix}-worker"
}

# --- DATA SOURCES ---
data "hcloud_image" "nat_gateway" {
  with_selector = "role=nat-gateway,location=${var.location}"
  most_recent   = true
}

data "hcloud_image" "k8s_node" {
  with_selector = "role=k8s-node,location=${var.location}"
  most_recent   = true
}

data "hcloud_ssh_key" "admin" {
  name = var.ssh_key_name
}

# --- NETWORK ---
resource "hcloud_network" "main" {
  name     = "${local.prefix}-net"
  ip_range = "10.0.0.0/16"

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_network_subnet" "k8s_nodes" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = "10.0.1.0/24"
}

# --- NAT GATEWAYS ---
# Primary NAT handles all outbound traffic. Secondary (prod only) runs a failover
# watchdog that uses the Hetzner API to reroute traffic to itself if the primary dies.
# Failover is one-directional — `terraform apply` restores the primary route.

resource "hcloud_server" "nat" {
  name        = "${local.prefix}-nat"
  image       = data.hcloud_image.nat_gateway.id
  server_type = var.nat_gateway_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]
  labels      = { cluster = local.prefix, role = "nat" }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.nat_primary_ip
  }

  user_data = replace(replace(
    file("${path.module}/templates/cloud-init-nat-primary.yaml"),
    "__HOSTNAME__", "${local.prefix}-nat"),
    "__TAILSCALE_AUTH_NAT_KEY__", tailscale_tailnet_key.nat.key,
  )

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data]
  }
}

resource "hcloud_server" "nat_secondary" {
  count       = local.cluster_config[var.env].nat_count > 1 ? 1 : 0
  name        = "${local.prefix}-nat-02"
  image       = data.hcloud_image.nat_gateway.id
  server_type = var.nat_gateway_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]
  labels      = { cluster = local.prefix, role = "nat" }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.nat_secondary_ip
  }

  user_data = replace(replace(replace(replace(replace(
    file("${path.module}/templates/cloud-init-nat-secondary.yaml"),
    "__HOSTNAME__", "${local.prefix}-nat-02"),
    "__TAILSCALE_AUTH_NAT_KEY__", tailscale_tailnet_key.nat.key),
    "__PEER_NAT_IP__", local.nat_primary_ip),
    "__HCLOUD_TOKEN__", var.token),
    "__HCLOUD_NETWORK_ID__", hcloud_network.main.id,
  )

  depends_on = [hcloud_server.nat]
}

resource "time_sleep" "wait_for_nat_config" {
  depends_on      = [hcloud_server.nat]
  create_duration = "60s"
}

resource "hcloud_network_route" "default_route" {
  network_id  = hcloud_network.main.id
  destination = "0.0.0.0/0"
  gateway     = local.nat_primary_ip
  depends_on  = [time_sleep.wait_for_nat_config]
}

# --- LOAD BALANCERS ---
resource "hcloud_load_balancer" "api" {
  name               = "${local.prefix}-lb-api"
  load_balancer_type = var.load_balancer_type
  location           = var.location

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_load_balancer_network" "api_net" {
  load_balancer_id = hcloud_load_balancer.api.id
  network_id       = hcloud_network.main.id
  ip               = local.api_load_balancer_ip
}

resource "hcloud_load_balancer_service" "k8s_api" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer" "ingress" {
  name               = "${local.prefix}-lb-ingress"
  load_balancer_type = var.load_balancer_type
  location           = var.location

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_load_balancer_network" "ingress_net" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  ip               = local.ingress_load_balancer_ip
  network_id       = hcloud_network.main.id
}

# --- PHASE 1: CONTROL PLANE INIT ---
resource "hcloud_server" "control_plane_init" {
  name        = local.init_cp_name
  image       = data.hcloud_image.k8s_node.id
  server_type = var.cp_server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]
  labels      = { cluster = local.prefix, role = "cp" }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.cp_map[local.init_cp_name]
  }

  user_data = replace(replace(replace(replace(replace(replace(
    replace(replace(replace(replace(replace(replace(
      replace(replace(replace(replace(replace(replace(
        file("${path.module}/templates/cloud-init-cp-init.yaml"),
        "__HOSTNAME__", local.init_cp_name),
        "__NODE_PRIVATE_IP__", local.cp_map[local.init_cp_name]),
        "__NETWORK_GATEWAY__", local.nat_primary_ip),
        "__KUBERNETES_API_LB_IP__", local.api_load_balancer_ip),
        "__KUBEADM_TOKEN__", local.kubeadm_token),
      "__KUBEADM_CERT_KEY__", random_id.kubeadm_cert_key.hex),
      "__TAILSCALE_AUTH_KEY__", tailscale_tailnet_key.cp.key),
      "__GIT_REPO_URL__", var.git_repo_url),
      "__ARGOCD_APPS_PATH__", "infra/argocd/envs/${var.env}"),
      "__CILIUM_VERSION__", var.cilium_version),
      "__HCLOUD_MTU__", tostring(var.hcloud_mtu)),
    "__ARGOCD_VERSION__", var.argocd_version),
    "__HCLOUD_TOKEN_READONLY__", var.token_readonly),
    "__HCLOUD_NETWORK_NAME__", hcloud_network.main.name),
    "__CCM_VERSION__", var.ccm_version),
    "__CSI_VERSION__", var.csi_version),
    "__SEALED_SECRETS_VERSION__", var.sealed_secrets_version),
    "__ENCRYPTION_KEY__", random_id.encryption_key.b64_std,
  )

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data]
  }

  depends_on = [hcloud_network_route.default_route]
}

resource "hcloud_load_balancer_target" "api_target_init" {
  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = hcloud_server.control_plane_init.id
  use_private_ip   = true
}

# --- PHASE 2: CONTROL PLANE JOIN (RECYCLE READY) ---
resource "hcloud_server" "control_plane_join" {
  for_each    = local.join_cps
  name        = each.key
  image       = data.hcloud_image.k8s_node.id
  server_type = var.cp_server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]
  labels      = { cluster = local.prefix, role = "cp" }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value
  }

  user_data = replace(replace(replace(replace(replace(replace(replace(replace(replace(
    file("${path.module}/templates/cloud-init-cp-join.yaml"),
    "__HOSTNAME__", each.key),
    "__NODE_PRIVATE_IP__", each.value),
    "__NETWORK_GATEWAY__", local.nat_primary_ip),
    "__KUBERNETES_API_LB_IP__", local.api_load_balancer_ip),
    "__KUBEADM_TOKEN__", local.kubeadm_token),
    "__KUBEADM_CERT_KEY__", random_id.kubeadm_cert_key.hex),
    "__TAILSCALE_AUTH_KEY__", tailscale_tailnet_key.cp.key),
    "__ENCRYPTION_KEY__", random_id.encryption_key.b64_std),
    "__CP_INIT_PRIVATE_IP__", local.cp_map[local.init_cp_name],
  )

  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [hcloud_server.control_plane_init]
}

resource "hcloud_load_balancer_target" "api_targets_join" {
  for_each         = hcloud_server.control_plane_join
  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = each.value.id
  use_private_ip   = true
}

# --- PHASE 3: WORKERS (RECYCLE READY) ---
resource "hcloud_server" "worker" {
  for_each    = local.worker_map
  name        = each.key
  image       = data.hcloud_image.k8s_node.id
  server_type = var.worker_server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]
  labels      = { cluster = local.prefix, role = "worker" }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value
  }

  user_data = replace(replace(replace(replace(replace(replace(
    file("${path.module}/templates/cloud-init-worker.yaml"),
    "__HOSTNAME__", each.key),
    "__NETWORK_GATEWAY__", local.nat_primary_ip),
    "__KUBERNETES_API_LB_IP__", local.api_load_balancer_ip),
    "__KUBEADM_TOKEN__", local.kubeadm_token),
    "__TAILSCALE_AUTH_KEY__", tailscale_tailnet_key.worker.key),
    "__CP_INIT_PRIVATE_IP__", local.cp_map[local.init_cp_name],
  )

  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [hcloud_server.control_plane_init]
}

# Ingress LB targets and services are managed by Hetzner CCM via
# annotations on the ingress-nginx LoadBalancer Service. CCM adopts
# this LB by name and configures NodePort routing + proxy protocol.
# See: infra/argocd/apps/225-ingress-nginx.yaml
