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

# HA expansion: joining SERVERS (embedded etcd; node1 was flipped to --cluster-init first).
# Deliberately separate resources, NOT a refactor of node1 into for_each -- changing node1's
# user_data would force destroy+recreate of the production node.
resource "hcloud_server" "node2" {
  name         = "unorouter-node2"
  server_type  = var.ha_node_type
  image        = "ubuntu-24.04"
  location     = "nbg1" # fsn1 capacity shortage 2026-07-23; 3-DC spread = quorum survives a DC outage
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.2"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version       = var.k3s_version
    tailscale_authkey = var.tailscale_authkey
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node2"
    private_ip        = "10.100.1.2"
  })

  depends_on = [hcloud_network_subnet.nodes]
}

resource "hcloud_server" "node3" {
  name         = "unorouter-node3"
  server_type  = var.ha_node_type
  image        = "ubuntu-24.04"
  location     = "hel1"
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.3"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version       = var.k3s_version
    tailscale_authkey = var.tailscale_authkey
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node3"
    private_ip        = "10.100.1.3"
  })

  depends_on = [hcloud_network_subnet.nodes]
}
