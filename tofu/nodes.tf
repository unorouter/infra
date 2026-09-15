# Talos fleet (2026-09-10). The image is the Image Factory snapshot (talos/README.md, label
# os=talos, newest wins). user_data is the rendered machine config under talos/clusterconfig/
# (gitignored), the way the Talos Hetzner guide creates nodes: both are read at create only,
# so they sit in ignore_changes and a plan on a checkout without the rendered files proposes
# nothing. A server the sniper bought with the same user data is imported, not recreated.
# No provider network: the nodes talk over the WireGuard mesh in talos/talconfig.yaml.
locals {
  nodes            = { node11 = "nbg1", node12 = "nbg1", node13 = "nbg1" }
  talos_config_dir = "${path.module}/../talos/clusterconfig"
}

data "hcloud_image" "talos" {
  with_selector     = "os=talos"
  with_architecture = "x86"
  most_recent       = true
}

resource "hcloud_server" "node" {
  for_each     = local.nodes
  name         = "unorouter-${each.key}"
  server_type  = "cx43"
  location     = each.value
  image        = data.hcloud_image.talos.id
  firewall_ids = [hcloud_firewall.node.id]
  labels       = { os = "talos" }
  user_data    = fileexists("${local.talos_config_dir}/unorouter-unorouter-${each.key}.yaml") ? file("${local.talos_config_dir}/unorouter-unorouter-${each.key}.yaml") : null

  lifecycle {
    ignore_changes = [user_data, image, ssh_keys]
  }
}

resource "hcloud_ssh_key" "operator" {
  name       = "unorouter-operator"
  public_key = var.ssh_public_key
}

# Data sources, not hcloud_server.node: a rule referencing the resource would cycle through
# firewall_ids.
data "hcloud_server" "node" {
  for_each = local.nodes
  name     = "unorouter-${each.key}"
}

resource "hcloud_firewall" "node" {
  name = "unorouter-node"

  # No inbound TCP at all. App traffic is the outbound Cloudflare tunnel, operator access
  # (kube api, talosctl) is Tailscale. Break-glass is a temporary rule from the Hetzner
  # console, then the VNC console, then rescue mode: docs/dr.md "Admin plane".

  # Tailscale direct peer paths (falls back to DERP relays without it, slower).
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # WireGuard mesh between the nodes (talos/talconfig.yaml networkInterfaces). WireGuard
  # never answers an unauthenticated packet, so world-open is the documented setting;
  # restricted to the node addresses anyway while every node has a stable one. Widen to the
  # provider range or 0.0.0.0/0 for a NAT'd node.
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = [for s in data.hcloud_server.node : "${s.ipv4_address}/32"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}
