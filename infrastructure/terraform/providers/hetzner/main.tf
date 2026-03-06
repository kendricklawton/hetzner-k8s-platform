terraform {
  required_version = ">= 1.5.0"
  backend "gcs" {}
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
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
variable "env" { type = string }          # dev | prod
variable "region" { type = string }       # plain string: eu-central, us-east, etc.
variable "token" { sensitive = true }
variable "ssh_key_name" { type = string }
variable "location" { type = string }     # Hetzner datacenter code: nbg1, fsn1, hel1, ash, hil

# Server Types
variable "k3s_server_type" { type = string }
variable "k3s_agent_type" { type = string }
variable "nat_gateway_type" { type = string }
variable "load_balancer_type" { type = string }
variable "git_repo_url" { type = string }

# Tailscale
variable "tailscale_auth_nat_key" { sensitive = true }
variable "tailscale_auth_k3s_server_key" { sensitive = true }
variable "tailscale_auth_k3s_agent_key" { sensitive = true }

# S3 Backup Bucket
variable "etcd_s3_access_key" { sensitive = true }
variable "etcd_s3_secret_key" { sensitive = true }
variable "etcd_s3_bucket" { type = string }
variable "etcd_s3_region" { type = string }
variable "etcd_s3_endpoint" { type = string }

# Manifest Versions
variable "ccm_version" { type = string }
variable "csi_version" { type = string }
variable "cilium_version" { type = string }
variable "ingress_nginx_version" { type = string }
variable "argocd_version" { type = string }
variable "sealed_secrets_version" { type = string }
variable "hcloud_mtu" {
  type    = number
  default = 1450
}

provider "hcloud" {
  token = var.token
}

locals {
  # {env}-{region} — both are plain input variables, no provider-specific derivation.
  # Pattern: {env}-{region}-{type}[-{role}][-{index}]
  # Examples: dev-eu-central-server-cp-01, prod-us-east-lb-api
  prefix = "${var.env}-${var.region}"

  # Infrastructure IPs
  nat_server_ip                = cidrhost("10.0.1.0/24", 2)
  k3s_api_load_balancer_ip     = cidrhost("10.0.1.0/24", 11)
  k3s_ingress_load_balancer_ip = cidrhost("10.0.1.0/24", 12)

  # Cluster size per environment
  cluster_config = {
    dev  = { server_count = 1, agent_count = 1 }
    prod = { server_count = 3, agent_count = 3 }
  }

  # Sticky name→IP maps for the recycle method
  server_map = {
    for i in range(local.cluster_config[var.env].server_count) :
    format("${local.prefix}-server-cp-%02d", i + 1) => cidrhost("10.0.1.0/24", i + 21)
  }

  agent_map = {
    for i in range(local.cluster_config[var.env].agent_count) :
    format("${local.prefix}-server-wk-%02d", i + 1) => cidrhost("10.0.1.0/24", i + 31)
  }

  # Split the init server out for cluster-init bootstrap
  init_server_name = format("${local.prefix}-server-cp-%02d", 1)
  join_servers     = { for k, v in local.server_map : k => v if k != local.init_server_name }

  manifest_injector_script = join("\n", [
    for filename, content in module.k3s_manifests.rendered_manifests :
    "echo '${base64encode(content)}' | base64 -d > /var/lib/rancher/k3s/server/manifests/${filename}"
  ])
}

# --- DATA SOURCES ---
data "hcloud_image" "nat_gateway" {
  with_selector = "role=nat-gateway,location=${var.location}"
  most_recent   = true
}

data "hcloud_image" "k3s_node" {
  with_selector = "role=k3s-node,location=${var.location}"
  most_recent   = true
}

data "hcloud_ssh_key" "admin" {
  name = var.ssh_key_name
}

# --- NETWORK ---
resource "hcloud_network" "main" {
  name     = "${local.prefix}-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "k3s_nodes" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.region  # Hetzner network zone — matches var.region (eu-central, us-east, us-west, ap-southeast)
  ip_range     = "10.0.1.0/24"
}

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
    ip         = local.nat_server_ip
  }

  user_data = templatefile("${path.module}/templates/cloud-init-nat.yaml", {
    tailscale_auth_nat_key = var.tailscale_auth_nat_key
    hostname               = "${local.prefix}-nat"
  })
}

resource "time_sleep" "wait_for_nat_config" {
  depends_on      = [hcloud_server.nat]
  create_duration = "60s"
}

resource "hcloud_network_route" "default_route" {
  network_id  = hcloud_network.main.id
  destination = "0.0.0.0/0"
  gateway     = local.nat_server_ip
  depends_on  = [time_sleep.wait_for_nat_config]
}

# --- LOAD BALANCERS ---
resource "hcloud_load_balancer" "api" {
  name               = "${local.prefix}-lb-api"
  load_balancer_type = var.load_balancer_type
  location           = var.location
}

resource "hcloud_load_balancer_network" "api_net" {
  load_balancer_id = hcloud_load_balancer.api.id
  network_id       = hcloud_network.main.id
  ip               = local.k3s_api_load_balancer_ip
}

resource "hcloud_load_balancer_service" "k3s_api" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
}

resource "hcloud_load_balancer" "ingress" {
  name               = "${local.prefix}-lb-ingress"
  load_balancer_type = var.load_balancer_type
  location           = var.location
}

resource "hcloud_load_balancer_network" "ingress_net" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  ip               = local.k3s_ingress_load_balancer_ip
  network_id       = hcloud_network.main.id
}

# --- K3S MODULE & TOKENS ---
resource "random_password" "k3s_token" {
  length  = 64
  special = false
}

module "k3s_manifests" {
  source                 = "../../modules/k3s_node"
  mtu                    = 1450
  k3s_load_balancer_ip   = local.k3s_api_load_balancer_ip
  cilium_version         = var.cilium_version
  ingress_nginx_version  = var.ingress_nginx_version
  sealed_secrets_version = var.sealed_secrets_version
  argocd_version         = var.argocd_version
  git_repo_url           = var.git_repo_url

  # Hetzner-specific manifests: cloud secret, CCM, CSI
  extra_manifests = {
    "000-hcloud-secret.yaml" = templatefile("${path.module}/bootstrap/000-hcloud-secret.yaml", {
      Token   = var.token
      Network = hcloud_network.main.name
    })
    "010-hcloud-ccm.yaml" = templatefile("${path.module}/bootstrap/010-hcloud-ccm.yaml", {
      CCMVersion = var.ccm_version
    })
    "020-hcloud-csi.yaml" = templatefile("${path.module}/bootstrap/020-hcloud-csi.yaml", {
      CSIVersion = var.csi_version
    })
  }
}

# --- PHASE 1: CONTROL PLANE INIT ---
resource "hcloud_server" "control_plane_init" {
  name        = local.init_server_name
  image       = data.hcloud_image.k3s_node.id
  server_type = var.k3s_server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.server_map[local.init_server_name]
  }

  user_data = templatefile("${path.module}/templates/cloud-init-server.yaml", {
    hostname                      = local.init_server_name
    k3s_token                     = random_password.k3s_token.result
    k3s_load_balancer_ip          = local.k3s_api_load_balancer_ip
    k3s_cluster_setting           = "cluster-init: true"
    etcd_s3_access_key            = var.etcd_s3_access_key
    etcd_s3_secret_key            = var.etcd_s3_secret_key
    etcd_s3_bucket                = var.etcd_s3_bucket
    etcd_s3_endpoint              = var.etcd_s3_endpoint
    network_gateway               = local.nat_server_ip
    tailscale_auth_k3s_server_key = var.tailscale_auth_k3s_server_key
    manifest_injector_script      = local.manifest_injector_script
  })

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
  for_each    = local.join_servers
  name        = each.key
  image       = data.hcloud_image.k3s_node.id
  server_type = var.k3s_server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value
  }

  user_data = templatefile("${path.module}/templates/cloud-init-server.yaml", {
    hostname                      = each.key
    k3s_token                     = random_password.k3s_token.result
    k3s_load_balancer_ip          = local.k3s_api_load_balancer_ip
    k3s_cluster_setting           = "server: https://${local.k3s_api_load_balancer_ip}:6443"
    etcd_s3_access_key            = var.etcd_s3_access_key
    etcd_s3_secret_key            = var.etcd_s3_secret_key
    etcd_s3_bucket                = var.etcd_s3_bucket
    etcd_s3_endpoint              = var.etcd_s3_endpoint
    network_gateway               = local.nat_server_ip
    tailscale_auth_k3s_server_key = var.tailscale_auth_k3s_server_key
    manifest_injector_script      = ""
  })

  depends_on = [hcloud_server.control_plane_init]
}

resource "hcloud_load_balancer_target" "api_targets_join" {
  for_each         = hcloud_server.control_plane_join
  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = each.value.id
  use_private_ip   = true
}

# --- PHASE 3: AGENTS (RECYCLE READY) ---
resource "hcloud_server" "agent" {
  for_each    = local.agent_map
  name        = each.key
  image       = data.hcloud_image.k3s_node.id
  server_type = var.k3s_agent_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value
  }

  user_data = templatefile("${path.module}/templates/cloud-init-agent.yaml", {
    hostname                     = each.key
    k3s_token                    = random_password.k3s_token.result
    k3s_control_plane_url        = "${local.k3s_api_load_balancer_ip}:6443"
    tailscale_auth_k3s_agent_key = var.tailscale_auth_k3s_agent_key
    network_gateway              = local.nat_server_ip
  })

  depends_on = [hcloud_server.control_plane_init]
}

resource "hcloud_load_balancer_target" "ingress_targets" {
  for_each         = hcloud_server.agent
  type             = "server"
  load_balancer_id = hcloud_load_balancer.ingress.id
  server_id        = each.value.id
  use_private_ip   = true
}

resource "hcloud_load_balancer_service" "ingress_http" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80
  proxyprotocol    = true

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "ingress_https" {
  load_balancer_id = hcloud_load_balancer.ingress.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443
  proxyprotocol    = true

  health_check {
    protocol = "tcp"
    port     = 443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
