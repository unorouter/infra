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

# Sniped budget replacement for the cpx22-era node3 (2026-07-23): created via raw API
# during a stock window, hand-joined, then tofu-imported. user_data below is the
# DR-rebuild path only -- the live server was built without cloud-init.
resource "hcloud_server" "node4" {
  name         = "unorouter-node4"
  server_type  = "cx23"
  image        = "ubuntu-24.04"
  location     = "hel1"
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.4"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version       = var.k3s_version
    tailscale_authkey = var.tailscale_authkey
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node4"
    private_ip        = "10.100.1.4"
  })

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}
