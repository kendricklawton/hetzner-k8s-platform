# OUTPUTS
output "api_endpoint" {
  value = local.api_load_balancer_ip
}

output "control_plane_init_hostname" {
  description = "The hostname of the primary control plane node for SSH access"
  value       = hcloud_server.control_plane_init.name
}

output "public_ingress_ip" {
  value = hcloud_load_balancer.ingress.ipv4
}

output "control_plane_ids" {
  value = concat([hcloud_server.control_plane_init.id], [for s in hcloud_server.control_plane_join : s.id])
}

output "worker_ids" {
  value = [for s in hcloud_server.worker : s.id]
}

output "nat_public_ip" {
  value = hcloud_server.nat.ipv4_address
}
