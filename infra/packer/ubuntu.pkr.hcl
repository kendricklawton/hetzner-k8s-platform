/*
  =============================================================================
  IMMUTABLE INFRASTRUCTURE BUILDS (GOLDEN IMAGES)
  =============================================================================
  Two image types:
  1. NAT Gateway — tiny router for outbound internet traffic (private nodes).
  2. K8s Node    — kubeadm/kubelet/kubectl, containerd, Helm.

  Shared provisioner scripts live in scripts/:
    base.sh, tailscale.sh, cleanup.sh

  Baked configs and bootstrap scripts live in files/:
    nat-bootstrap.sh, nat-failover.sh, kubeadm-bootstrap.sh,
    nat-tuning.conf, nat-iptables.rules, nat-netplan.yaml, nat-failover.service,
    k8s-tuning.conf, k8s-netplan.yaml, k8s-audit-policy.yaml, k8s-logrotate.conf
  =============================================================================
*/

packer {
  required_plugins {
    hcloud = {
      version = ">= 1.0.0"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}

variable "kubernetes_version" { type = string }

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "hcloud_ubuntu_version" { type = string }
variable "hcloud_nat_type" { type = string }
variable "hcloud_k8s_type" { type = string }

locals {
  timestamp = formatdate("YYMMDD", timestamp())
}

# --- SOURCES ---

source "hcloud" "nat_ash" {
  token         = var.hcloud_token
  image         = var.hcloud_ubuntu_version
  location      = "ash"
  server_type   = var.hcloud_nat_type
  ssh_username  = "root"
  snapshot_name = "ash-nat-gateway-ubuntu-amd64-${local.timestamp}"
  snapshot_labels = { role = "nat-gateway", location = "ash", version = local.timestamp }
}

source "hcloud" "k8s_ash" {
  token         = var.hcloud_token
  image         = var.hcloud_ubuntu_version
  location      = "ash"
  server_type   = var.hcloud_k8s_type
  ssh_username  = "root"
  snapshot_name = "ash-k8s-node-ubuntu-amd64-${local.timestamp}"
  snapshot_labels = { role = "k8s-node", location = "ash", version = local.timestamp }
}

# =============================================================================
# BUILD: NAT GATEWAY
# =============================================================================

build {
  name    = "nat"
  sources = ["source.hcloud.nat_ash"]

  provisioner "shell" { script = "${path.root}/scripts/base.sh" }

  # iptables-persistent (preconfigure debconf to avoid interactive prompt)
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections",
      "echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections",
      "apt-get install -y iptables-persistent",
    ]
  }

  # Kernel tuning for high-throughput NAT (BBR, conntrack, port range)
  provisioner "file" {
    source      = "${path.root}/files/nat-tuning.conf"
    destination = "/etc/sysctl.d/99-nat-tuning.conf"
  }
  provisioner "shell" { inline = ["sysctl --system"] }

  # iptables rules (accept internal + tailscale, drop everything else, NAT masquerade)
  provisioner "file" {
    source      = "${path.root}/files/nat-iptables.rules"
    destination = "/etc/iptables/rules.v4"
  }

  provisioner "shell" { script = "${path.root}/scripts/tailscale.sh" }

  # Remove hc-utils (races with systemd-networkd on private interface)
  provisioner "shell" { inline = ["apt-get remove -y hc-utils || true"] }

  # Netplan: private interface (enp7s0). Public interface left to cloud-init.
  provisioner "file" {
    source      = "${path.root}/files/nat-netplan.yaml"
    destination = "/etc/netplan/60-private-net.yaml"
  }
  provisioner "shell" { inline = ["chmod 0600 /etc/netplan/60-private-net.yaml"] }

  # Bootstrap + failover scripts
  provisioner "file" {
    source      = "${path.root}/files/nat-bootstrap.sh"
    destination = "/usr/local/bin/nat-bootstrap.sh"
  }
  provisioner "file" {
    source      = "${path.root}/files/nat-failover.sh"
    destination = "/usr/local/bin/nat-failover.sh"
  }
  provisioner "shell" { inline = ["chmod 0700 /usr/local/bin/nat-bootstrap.sh /usr/local/bin/nat-failover.sh"] }

  # Failover systemd unit
  provisioner "file" {
    source      = "${path.root}/files/nat-failover.service"
    destination = "/etc/systemd/system/nat-failover.service"
  }

  provisioner "shell" { script = "${path.root}/scripts/cleanup.sh" }
}

# =============================================================================
# BUILD: K8S NODE (kubeadm)
# =============================================================================

build {
  name    = "k8s"
  sources = ["source.hcloud.k8s_ash"]

  provisioner "shell" { script = "${path.root}/scripts/base.sh" }

  # Additional packages
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get install -y gpg apt-transport-https python3 wireguard logrotate open-iscsi nfs-common cryptsetup systemd-timesyncd fping",
      "systemctl enable systemd-timesyncd",
      "timedatectl set-ntp true"
    ]
  }

  # Containerd
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get install -y containerd",
      "mkdir -p /etc/containerd",
      "containerd config default > /etc/containerd/config.toml",
      "sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",
      "systemctl enable containerd"
    ]
  }

  # Kubernetes (kubeadm, kubelet, kubectl)
  provisioner "shell" {
    inline = [
      "K8S_VERSION='${var.kubernetes_version}'",
      "K8S_MINOR=$(echo $K8S_VERSION | sed 's/^v//' | cut -d. -f1-2)",
      "curl -fsSL https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
      "echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$K8S_MINOR/deb/ /\" > /etc/apt/sources.list.d/kubernetes.list",
      "apt-get update",
      "PKG_VERSION=$(echo $K8S_VERSION | sed 's/^v//')",
      "apt-get install -y kubelet=$${PKG_VERSION}-* kubeadm=$${PKG_VERSION}-* kubectl=$${PKG_VERSION}-*",
      "apt-mark hold kubelet kubeadm kubectl"
    ]
  }

  # crictl config
  provisioner "shell" {
    inline = ["printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\\nimage-endpoint: unix:///run/containerd/containerd.sock\\n' > /etc/crictl.yaml"]
  }

  # Helm
  provisioner "shell" {
    inline = ["curl --proto =https -fsSL https://raw.githubusercontent.com/helm/helm/v3.17.0/scripts/get-helm-3 | VERIFY_CHECKSUM=true bash"]
  }

  provisioner "shell" { script = "${path.root}/scripts/tailscale.sh" }

  # Kernel tuning (IP forwarding, bridge netfilter, inotify, panic handlers)
  provisioner "file" {
    source      = "${path.root}/files/k8s-tuning.conf"
    destination = "/etc/sysctl.d/99-k8s.conf"
  }
  provisioner "shell" {
    inline = [
      "modprobe br_netfilter",
      "printf 'br_netfilter\n' > /etc/modules-load.d/k8s.conf",
      "sysctl --system"
    ]
  }

  # Disable cloud-init networking + remove hc-utils
  provisioner "shell" {
    inline = [
      "echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg",
      "apt-get remove -y hc-utils || true"
    ]
  }

  # Netplan: private-only interface with metadata route
  provisioner "file" {
    source      = "${path.root}/files/k8s-netplan.yaml"
    destination = "/etc/netplan/60-private-net.yaml"
  }
  provisioner "shell" { inline = ["chmod 0600 /etc/netplan/60-private-net.yaml"] }

  # Audit policy
  provisioner "shell" { inline = ["mkdir -p /etc/kubernetes"] }
  provisioner "file" {
    source      = "${path.root}/files/k8s-audit-policy.yaml"
    destination = "/etc/kubernetes/audit-policy.yaml"
  }
  provisioner "shell" { inline = ["chmod 0600 /etc/kubernetes/audit-policy.yaml"] }

  # Bootstrap script
  provisioner "file" {
    source      = "${path.root}/files/kubeadm-bootstrap.sh"
    destination = "/usr/local/bin/kubeadm-bootstrap.sh"
  }
  provisioner "shell" { inline = ["chmod 0700 /usr/local/bin/kubeadm-bootstrap.sh"] }

  # Log rotation
  provisioner "file" {
    source      = "${path.root}/files/k8s-logrotate.conf"
    destination = "/etc/logrotate.d/k8s-bootstrap"
  }
  provisioner "shell" {
    inline = [
      "sed -i 's/#SystemMaxUse=/SystemMaxUse=1G/'     /etc/systemd/journald.conf",
      "sed -i 's/#SystemKeepFree=/SystemKeepFree=1G/' /etc/systemd/journald.conf"
    ]
  }

  provisioner "shell" { script = "${path.root}/scripts/cleanup.sh" }
}
