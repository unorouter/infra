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
# Deliberately separate resources, NOT a refactor of node1 into for_each -- changing node1's
# user_data would force destroy+recreate of a production node. node2/node3 (interim cpx22)
# were replaced by sniped cx23s (node4/node5) on 2026-07-23; numbering is cattle.
# Sniped 8GB upgrade of the cx23 node5 (2026-07-24): cx33 grabbed during a nbg1 stock window,
# hand-joined, then tofu-imported. Same DC as the node it replaced (nbg1) so the 3-DC quorum
# spread held; fleet is now uniform cx33 8+8+8. user_data is the DR-rebuild path only.
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

# Sniped 8GB upgrade of the cx23 node4 (2026-07-24): cx33 grabbed during a hel1 stock
# window, hand-joined, then tofu-imported. Same DC as the node it replaced (hel1) so the
# 3-DC quorum spread is preserved. user_data below is the DR-rebuild path only -- the live
# server was built without cloud-init.
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
