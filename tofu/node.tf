resource "hcloud_ssh_key" "operator" {
  name       = "unorouter-operator"
  public_key = var.ssh_public_key
}

resource "hcloud_server" "node1" {
  name        = "unorouter-node1"
  server_type = var.node_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.1"
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    k3s_version       = var.k3s_version
    tailscale_authkey = var.tailscale_authkey
  })

  depends_on = [hcloud_network_subnet.nodes]
}
