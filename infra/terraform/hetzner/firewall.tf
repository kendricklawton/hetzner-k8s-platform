# Firewall rules per node role. Shared patterns (internal VPC, Tailscale, outbound)
# are defined once in locals and composed per role.

locals {
  # All roles: allow internal VPC traffic (nodes + pods + services)
  internal_rules = [
    { direction = "in", protocol = "tcp", port = "any", source_ips = ["10.0.0.0/8"] },
    { direction = "in", protocol = "udp", port = "any", source_ips = ["10.0.0.0/8"] },
    { direction = "in", protocol = "icmp", port = null, source_ips = ["10.0.0.0/8"] },
  ]

  # All roles: Tailscale direct + WireGuard fallback
  tailscale_rules = [
    { direction = "in", protocol = "udp", port = "41641", source_ips = ["0.0.0.0/0"] },
    { direction = "in", protocol = "udp", port = "51820", source_ips = ["0.0.0.0/0"] },
  ]

  # All roles: unrestricted outbound
  outbound_rules = [
    { direction = "out", protocol = "tcp", port = "any", destination_ips = ["0.0.0.0/0", "::/0"] },
    { direction = "out", protocol = "udp", port = "any", destination_ips = ["0.0.0.0/0", "::/0"] },
    { direction = "out", protocol = "icmp", port = null, destination_ips = ["0.0.0.0/0", "::/0"] },
  ]

  # CP-only: K8s API + etcd peer communication
  cp_rules = [
    { direction = "in", protocol = "tcp", port = "6443", source_ips = ["10.0.0.0/8"] },
    { direction = "in", protocol = "tcp", port = "2379-2380", source_ips = ["10.0.0.0/8"] },
  ]

  # Worker-only: NodePort range + HTTP/HTTPS for ingress
  worker_rules = [
    { direction = "in", protocol = "tcp", port = "30000-32767", source_ips = ["10.0.0.0/8"] },
    { direction = "in", protocol = "tcp", port = "80", source_ips = ["0.0.0.0/0"] },
    { direction = "in", protocol = "tcp", port = "443", source_ips = ["0.0.0.0/0"] },
  ]

  # Compose full rule sets per role
  firewall_roles = {
    nat = {
      rules = concat(local.internal_rules, local.tailscale_rules, local.outbound_rules)
    }
    cp = {
      rules = concat(local.internal_rules, local.cp_rules, local.tailscale_rules, local.outbound_rules)
    }
    worker = {
      rules = concat(local.internal_rules, local.worker_rules, local.tailscale_rules, local.outbound_rules)
    }
  }
}

resource "hcloud_firewall" "role" {
  for_each = local.firewall_roles
  name     = "${local.prefix}-fw-${each.key}"

  dynamic "rule" {
    for_each = each.value.rules
    content {
      direction       = rule.value.direction
      protocol        = rule.value.protocol
      port            = rule.value.port
      source_ips      = lookup(rule.value, "source_ips", null)
      destination_ips = lookup(rule.value, "destination_ips", null)
    }
  }

  apply_to { label_selector = "cluster=${local.prefix},role=${each.key}" }
}
