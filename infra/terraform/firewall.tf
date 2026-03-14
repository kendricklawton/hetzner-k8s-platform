# --- SHARED OUTBOUND + INTERNAL RULES ---
# All roles need: internal cluster traffic, outbound internet, Tailscale

# --- NAT GATEWAY FIREWALL ---
resource "hcloud_firewall" "nat" {
  name = "${local.prefix}-fw-nat"

  # Internal network
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["10.0.0.0/16"]
  }

  # Tailscale direct + WireGuard fallback
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = ["0.0.0.0/0"]
  }

  # Outbound (all)
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  apply_to { label_selector = "cluster=${local.prefix},role=nat" }
}

# --- CONTROL PLANE FIREWALL ---
resource "hcloud_firewall" "cp" {
  name = "${local.prefix}-fw-cp"

  # Internal network
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["10.0.0.0/16"]
  }

  # Kubernetes API — only reachable from private network + LB.
  # External access is via Tailscale or the API load balancer (which is also on 10.0.0.0/16).
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["10.0.0.0/16"]
  }

  # etcd peer communication (CP nodes only)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "2379-2380"
    source_ips = ["10.0.0.0/16"]
  }

  # Tailscale direct + WireGuard fallback
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = ["0.0.0.0/0"]
  }

  # Outbound (all)
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  apply_to { label_selector = "cluster=${local.prefix},role=cp" }
}

# --- WORKER FIREWALL ---
resource "hcloud_firewall" "worker" {
  name = "${local.prefix}-fw-worker"

  # Internal network
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["10.0.0.0/16"]
  }

  # NodePort range (ingress traffic via LB)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "30000-32767"
    source_ips = ["10.0.0.0/16"]
  }

  # HTTP/HTTPS (ingress-nginx on workers — IPv6 disabled on all nodes)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0"]
  }

  # Tailscale direct + WireGuard fallback
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = ["0.0.0.0/0"]
  }

  # Outbound (all)
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  apply_to { label_selector = "cluster=${local.prefix},role=worker" }
}
