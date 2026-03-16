/*
  =============================================================================
  PROJECT PLATFORM: IMMUTABLE INFRASTRUCTURE BUILDS (GOLDEN IMAGES)
  =============================================================================
  What is this file?
  This is a HashiCorp Packer template. Instead of booting up an empty Linux
  server and running installation scripts every time we want to scale up,
  Packer boots a temporary server, installs all our software, takes a
  "snapshot" (Golden Image) of the hard drive, and then deletes the temporary
  server.

  Terraform will then use these pre-baked snapshots to boot new servers in
  seconds instead of minutes.

  We build two types of images here:
  1. NAT Gateway: A tiny router that handles outbound internet traffic for
     private cluster nodes. Baked with bootstrap + failover scripts, netplan,
     and systemd units. Cloud-init only writes a small env file.
  2. K8s Node:   A heavy-duty worker/control-plane node pre-loaded with
     vanilla Kubernetes (kubeadm/kubelet/kubectl), containerd, gVisor,
     Helm, and a unified bootstrap script. Cloud-init only writes a small
     env file — the baked script handles all roles (cp-init, cp-join, worker).

  Shared provisioner steps live in scripts/:
  - base.sh       — apt update/upgrade, common packages, SSH hardening
  - tailscale.sh  — Tailscale install + state cleanup
  - cleanup.sh    — apt clean, SSH host key removal, cloud-init reset

  Baked bootstrap scripts live in files/:
  - nat-bootstrap.sh    — NAT gateway first-boot orchestration
  - nat-failover.sh     — Secondary NAT failover watchdog
  - kubeadm-bootstrap.sh — Unified K8s node bootstrap (all roles)
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

# VARIABLES
variable "kubernetes_version" {
  type = string
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "hcloud_ubuntu_version" {
  type = string
}

variable "hcloud_nat_type" {
  type = string
}

variable "hcloud_k8s_type" {
  type = string
}

# LOCALS
locals {
  timestamp = formatdate("YYMMDD", timestamp())
}

# SOURCES: NAT GATEWAY
source "hcloud" "nat_ash" {
  token         = var.hcloud_token
  image         = var.hcloud_ubuntu_version
  location      = "ash"
  server_type   = var.hcloud_nat_type
  ssh_username  = "root"
  snapshot_name = "ash-nat-gateway-ubuntu-amd64-${local.timestamp}"
  snapshot_labels = {
    role     = "nat-gateway"
    location = "ash"
    version  = local.timestamp
  }
}

source "hcloud" "nat_hil" {
  token         = var.hcloud_token
  image         = var.hcloud_ubuntu_version
  location      = "hil"
  server_type   = var.hcloud_nat_type
  ssh_username  = "root"
  snapshot_name = "hil-nat-gateway-ubuntu-amd64-${local.timestamp}"
  snapshot_labels = {
    role     = "nat-gateway"
    location = "hil"
    version  = local.timestamp
  }
}

# SOURCES: K8S NODE
source "hcloud" "k8s_ash" {
  token         = var.hcloud_token
  image         = var.hcloud_ubuntu_version
  location      = "ash"
  server_type   = var.hcloud_k8s_type
  ssh_username  = "root"
  snapshot_name = "ash-k8s-node-ubuntu-amd64-${local.timestamp}"
  snapshot_labels = {
    role     = "k8s-node"
    location = "ash"
    version  = local.timestamp
  }
}

source "hcloud" "k8s_hil" {
  token         = var.hcloud_token
  image         = var.hcloud_ubuntu_version
  location      = "hil"
  server_type   = var.hcloud_k8s_type
  ssh_username  = "root"
  snapshot_name = "hil-k8s-node-ubuntu-amd64-${local.timestamp}"
  snapshot_labels = {
    role     = "k8s-node"
    location = "hil"
    version  = local.timestamp
  }
}

# BUILD: NAT GATEWAY
build {
  name    = "nat"
  sources = ["source.hcloud.nat_ash", "source.hcloud.nat_hil"]

  # --- SHARED: Base packages + SSH hardening ---
  provisioner "shell" {
    script = "${path.root}/scripts/base.sh"
  }

  # --- NAT-SPECIFIC: iptables-persistent ---
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections",
      "echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections",
      "apt-get install -y iptables-persistent",
    ]
  }

  # --- NAT-SPECIFIC: Kernel tuning for high throughput NAT ---
  provisioner "shell" {
    inline = [
      "cat << 'EOF' > /etc/sysctl.d/99-nat-tuning.conf",
      "net.ipv4.ip_forward=1",
      "net.core.default_qdisc=fq",
      "net.ipv4.tcp_congestion_control=bbr",
      "net.netfilter.nf_conntrack_max=1048576",
      "net.ipv4.ip_local_port_range=1024 65535",
      "net.ipv4.tcp_tw_reuse=1",
      "EOF",
      "sysctl --system"
    ]
  }

  # --- NAT-SPECIFIC: Firewall rules ---
  provisioner "shell" {
    inline = [
      "cat << 'EOF' > /etc/iptables/rules.v4",
      "*filter",
      ":INPUT ACCEPT [0:0]",
      ":FORWARD ACCEPT [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
      "-A INPUT -i lo -j ACCEPT",
      "-A INPUT -p udp --dport 41641 -j ACCEPT",
      "-A INPUT -s 10.0.0.0/16 -j ACCEPT",
      "-A INPUT -j DROP",
      "-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
      "-A FORWARD -s 10.0.0.0/16 -j ACCEPT",
      "COMMIT",
      "*nat",
      ":PREROUTING ACCEPT [0:0]",
      ":INPUT ACCEPT [0:0]",
      ":OUTPUT ACCEPT [0:0]",
      ":POSTROUTING ACCEPT [0:0]",
      "COMMIT",
      "EOF"
    ]
  }

  # --- SHARED: Tailscale ---
  provisioner "shell" {
    script = "${path.root}/scripts/tailscale.sh"
  }

  # --- NAT-SPECIFIC: Bake netplan config ---
  provisioner "shell" {
    inline = [
      "cat << 'EOF' > /etc/netplan/60-private-net.yaml",
      "network:",
      "  version: 2",
      "  ethernets:",
      "    private:",
      "      match:",
      "        name: \"e*\"",
      "      dhcp4: true",
      "      dhcp4-overrides:",
      "        use-routes: false",
      "      routes:",
      "      - to: 10.0.0.1",
      "        scope: link",
      "      - to: 10.0.0.0/16",
      "        via: 10.0.0.1",
      "EOF",
      "chmod 0600 /etc/netplan/60-private-net.yaml"
    ]
  }

  # --- NAT-SPECIFIC: Bake bootstrap + failover scripts ---
  provisioner "file" {
    source      = "${path.root}/files/nat-bootstrap.sh"
    destination = "/usr/local/bin/nat-bootstrap.sh"
  }

  provisioner "file" {
    source      = "${path.root}/files/nat-failover.sh"
    destination = "/usr/local/bin/nat-failover.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod 0700 /usr/local/bin/nat-bootstrap.sh /usr/local/bin/nat-failover.sh",
    ]
  }

  # --- NAT-SPECIFIC: Bake failover systemd unit ---
  provisioner "shell" {
    inline = [
      "cat << 'EOF' > /etc/systemd/system/nat-failover.service",
      "[Unit]",
      "Description=NAT Gateway Failover Watchdog",
      "After=network-online.target",
      "Wants=network-online.target",
      "",
      "[Service]",
      "Type=simple",
      "ExecStart=/usr/local/bin/nat-failover.sh",
      "Restart=always",
      "RestartSec=10",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF"
    ]
  }

  # --- SHARED: Cleanup ---
  provisioner "shell" {
    script = "${path.root}/scripts/cleanup.sh"
  }
}

# BUILD: K8S NODE (vanilla Kubernetes via kubeadm)
build {
  name    = "k8s"
  sources = ["source.hcloud.k8s_ash", "source.hcloud.k8s_hil"]

  # --- SHARED: Base packages + SSH hardening ---
  provisioner "shell" {
    script = "${path.root}/scripts/base.sh"
  }

  # --- K8S-SPECIFIC: Additional packages ---
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get install -y gpg apt-transport-https python3 wireguard logrotate open-iscsi nfs-common cryptsetup systemd-timesyncd fping",
      "systemctl enable systemd-timesyncd",
      "timedatectl set-ntp true"
    ]
  }

  # --- K8S-SPECIFIC: Containerd ---
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

  # --- K8S-SPECIFIC: gVisor ---
  provisioner "shell" {
    inline = [
      "ARCH=$(uname -m)",
      "URL=https://storage.googleapis.com/gvisor/releases/release/latest/$${ARCH}",
      "wget $${URL}/runsc $${URL}/runsc.sha512",
      "sha512sum -c runsc.sha512",
      "rm -f runsc.sha512",
      "chmod a+rx runsc && mv runsc /usr/local/bin && ln -sf /usr/local/bin/runsc /usr/bin/runsc",
      "wget $${URL}/containerd-shim-runsc-v1 $${URL}/containerd-shim-runsc-v1.sha512",
      "sha512sum -c containerd-shim-runsc-v1.sha512",
      "rm -f containerd-shim-runsc-v1.sha512",
      "chmod a+rx containerd-shim-runsc-v1 && mv containerd-shim-runsc-v1 /usr/local/bin && ln -sf /usr/local/bin/containerd-shim-runsc-v1 /usr/bin/containerd-shim-runsc-v1",
      "cat >> /etc/containerd/config.toml << 'EOF'",
      "",
      "[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc]",
      "  runtime_type = \"io.containerd.runsc.v1\"",
      "EOF"
    ]
  }

  # --- K8S-SPECIFIC: Kubernetes ---
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

  # --- K8S-SPECIFIC: crictl (SHA256 verified) ---
  provisioner "shell" {
    inline = [
      "K8S_VERSION='${var.kubernetes_version}'",
      "CRICTL_VERSION=$(echo $K8S_VERSION | sed 's/^v//')",
      "ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')",
      "CRICTL_URL=https://github.com/kubernetes-sigs/cri-tools/releases/download/v$${CRICTL_VERSION}",
      "wget -q $${CRICTL_URL}/crictl-v$${CRICTL_VERSION}-linux-$${ARCH}.tar.gz",
      "wget -q $${CRICTL_URL}/crictl-v$${CRICTL_VERSION}-linux-$${ARCH}.tar.gz.sha256",
      "sha256sum -c crictl-v$${CRICTL_VERSION}-linux-$${ARCH}.tar.gz.sha256",
      "tar -xzf crictl-v$${CRICTL_VERSION}-linux-$${ARCH}.tar.gz -C /usr/local/bin",
      "rm -f crictl-v$${CRICTL_VERSION}-linux-$${ARCH}.tar.gz crictl-v$${CRICTL_VERSION}-linux-$${ARCH}.tar.gz.sha256",
      "chmod +x /usr/local/bin/crictl",
      "printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\\nimage-endpoint: unix:///run/containerd/containerd.sock\\n' > /etc/crictl.yaml"
    ]
  }

  # --- K8S-SPECIFIC: Helm ---
  provisioner "shell" {
    inline = [
      "curl --proto =https -fsSL https://raw.githubusercontent.com/helm/helm/v3.17.0/scripts/get-helm-3 | VERIFY_CHECKSUM=true bash"
    ]
  }

  # --- SHARED: Tailscale ---
  provisioner "shell" {
    script = "${path.root}/scripts/tailscale.sh"
  }

  # --- K8S-SPECIFIC: Kernel tuning ---
  provisioner "shell" {
    inline = [
      "modprobe br_netfilter",
      "printf 'br_netfilter\n' > /etc/modules-load.d/k8s.conf",
      "echo 'net.ipv4.ip_forward = 1'                    >  /etc/sysctl.d/99-k8s.conf",
      "echo 'net.ipv6.conf.all.forwarding = 1'           >> /etc/sysctl.d/99-k8s.conf",
      "echo 'net.bridge.bridge-nf-call-iptables = 1'     >> /etc/sysctl.d/99-k8s.conf",
      "echo 'net.bridge.bridge-nf-call-ip6tables = 1'    >> /etc/sysctl.d/99-k8s.conf",
      "echo 'fs.inotify.max_user_instances = 8192'       >> /etc/sysctl.d/99-k8s.conf",
      "echo 'fs.inotify.max_user_watches = 524288'       >> /etc/sysctl.d/99-k8s.conf",
      "sysctl --system"
    ]
  }

  # --- K8S-SPECIFIC: Bake netplan config ---
  provisioner "shell" {
    inline = [
      "cat << 'EOF' > /etc/netplan/60-private-net.yaml",
      "network:",
      "  version: 2",
      "  ethernets:",
      "    private:",
      "      match:",
      "        name: \"e*\"",
      "      dhcp4: true",
      "      nameservers:",
      "        addresses: [1.1.1.1, 8.8.8.8]",
      "      routes:",
      "        - to: 0.0.0.0/0",
      "          via: 10.0.0.1",
      "          on-link: true",
      "EOF",
      "chmod 0600 /etc/netplan/60-private-net.yaml"
    ]
  }

  # --- K8S-SPECIFIC: Bake audit policy ---
  provisioner "shell" {
    inline = [
      "mkdir -p /etc/kubernetes",
      "cat << 'EOF' > /etc/kubernetes/audit-policy.yaml",
      "apiVersion: audit.k8s.io/v1",
      "kind: Policy",
      "rules:",
      "- level: Metadata",
      "EOF",
      "chmod 0600 /etc/kubernetes/audit-policy.yaml"
    ]
  }

  # --- K8S-SPECIFIC: Bake bootstrap script ---
  provisioner "file" {
    source      = "${path.root}/files/kubeadm-bootstrap.sh"
    destination = "/usr/local/bin/kubeadm-bootstrap.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod 0700 /usr/local/bin/kubeadm-bootstrap.sh",
    ]
  }

  # --- K8S-SPECIFIC: Trivy security scan ---
  provisioner "shell" {
    inline = [
      "wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | apt-key add -",
      "echo \"deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main\" | tee /etc/apt/sources.list.d/trivy.list",
      "apt-get update && apt-get install -y trivy",
      "trivy filesystem --exit-code 1 --severity CRITICAL --ignore-unfixed /"
    ]
  }

  # --- K8S-SPECIFIC: Log rotation ---
  provisioner "shell" {
    inline = [
      "echo '/var/log/tailscale-join.log {'           >  /etc/logrotate.d/k8s-bootstrap",
      "echo '    size 10M'                            >> /etc/logrotate.d/k8s-bootstrap",
      "echo '    rotate 5'                            >> /etc/logrotate.d/k8s-bootstrap",
      "echo '    compress'                            >> /etc/logrotate.d/k8s-bootstrap",
      "echo '    missingok'                           >> /etc/logrotate.d/k8s-bootstrap",
      "echo '    notifempty'                          >> /etc/logrotate.d/k8s-bootstrap",
      "echo '    copytruncate'                        >> /etc/logrotate.d/k8s-bootstrap",
      "echo '}'                                       >> /etc/logrotate.d/k8s-bootstrap",
      "sed -i 's/#SystemMaxUse=/SystemMaxUse=1G/'     /etc/systemd/journald.conf",
      "sed -i 's/#SystemKeepFree=/SystemKeepFree=1G/' /etc/systemd/journald.conf"
    ]
  }

  # --- SHARED: Cleanup ---
  provisioner "shell" {
    script = "${path.root}/scripts/cleanup.sh"
  }
}
