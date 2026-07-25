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
    k3s_token         = var.k3s_token
  })

  # live node1 was hand-migrated to etcd (--cluster-init etc.); template updates must NOT
  # replace the production node -- they take effect only on a genuine DR rebuild
  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# HA expansion: joining SERVERS (embedded etcd; node1 was flipped to --cluster-init first).
# Deliberately separate resources, NOT a for_each refactor -- that would change node1's
# user_data and force destroy+recreate of a production node. Node numbering is cattle.
#
# This server was hand-joined then tofu-imported, so user_data here is the DR-rebuild path
# only; it does not describe the running machine.
resource "hcloud_server" "node7" {
  name         = "unorouter-node7"
  server_type  = "cx33"
  location     = "nbg1" # 3-DC spread with fsn1 (node1) + hel1 (node6): quorum survives a DC outage
  image        = "ubuntu-24.04"
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.4"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version       = var.k3s_version
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node7"
    private_ip        = "10.100.1.4"
  })

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# Hand-joined then tofu-imported, like node7: user_data is the DR-rebuild path only.
resource "hcloud_server" "node6" {
  name         = "unorouter-node6"
  server_type  = "cx33"
  image        = "ubuntu-24.04"
  location     = "hel1"
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.2"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version       = var.k3s_version
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node6"
    private_ip        = "10.100.1.2"
  })

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}
