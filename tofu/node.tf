resource "hcloud_ssh_key" "operator" {
  name       = "unorouter-operator"
  public_key = var.ssh_public_key
}

# Hand-joined then tofu-imported, like node8/node9: user_data is the DR-rebuild path only.
# Replaced the original node1 (cx33, fsn1) on 2026-09-04; the fleet is now three cx43s.
resource "hcloud_server" "node10" {
  name         = "unorouter-node10"
  server_type  = "cx43"
  location     = "hel1"
  image        = "ubuntu-24.04"
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.4"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version = var.k3s_version
    k3s_token   = var.k3s_token
    node_name   = "unorouter-node10"
    private_ip  = "10.100.1.4"
  })

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# Joining SERVERS (embedded etcd). Deliberately separate resources, NOT a for_each refactor:
# that would rewrite user_data and force destroy+recreate of production nodes. Numbering is cattle.
#
# This server was hand-joined then tofu-imported, so user_data here is the DR-rebuild path
# only; it does not describe the running machine.
resource "hcloud_server" "node9" {
  name         = "unorouter-node9"
  server_type  = "cx43"
  location     = "nbg1" # DC spread with hel1 (node8, node10)
  image        = "ubuntu-24.04"
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.2"
  }

  user_data = templatefile("${path.module}/cloud-init-join.yaml.tftpl", {
    k3s_version       = var.k3s_version
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node9"
    private_ip        = "10.100.1.2"
  })

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# Hand-joined then tofu-imported, like node9: user_data is the DR-rebuild path only.
resource "hcloud_server" "node8" {
  name         = "unorouter-node8"
  server_type  = "cx43"
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
    k3s_token         = var.k3s_token
    node_name         = "unorouter-node8"
    private_ip        = "10.100.1.3"
  })

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}
