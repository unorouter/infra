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

# Talos fleet (2026-09-10). The image is the Image Factory snapshot uploaded by
# bootstrap/talos/upload-image.sh (label os=talos, newest wins). user_data is the rendered
# machine config under bootstrap/talos/clusterconfig/ (gitignored): both are read at create
# only, so they sit in ignore_changes and a plan on a checkout without the rendered files
# proposes nothing. Each node was configured by bootstrap/talos/spare-join.sh and imported.
data "hcloud_image" "talos" {
  with_selector     = "os=talos"
  with_architecture = "x86"
  most_recent       = true
}

locals {
  talos_config_dir = "${path.module}/../bootstrap/talos/clusterconfig"
}

resource "hcloud_server" "node11" {
  name         = "unorouter-node11"
  server_type  = "cx43"
  location     = "nbg1"
  image        = data.hcloud_image.talos.id
  firewall_ids = [hcloud_firewall.node.id]
  labels       = { os = "talos" }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.1"
  }

  user_data = fileexists("${local.talos_config_dir}/unorouter-unorouter-node11.yaml") ? file("${local.talos_config_dir}/unorouter-unorouter-node11.yaml") : null

  lifecycle {
    ignore_changes = [user_data, image, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

resource "hcloud_server" "node12" {
  name         = "unorouter-node12"
  server_type  = "cx43"
  location     = "nbg1"
  image        = data.hcloud_image.talos.id
  firewall_ids = [hcloud_firewall.node.id]
  labels       = { os = "talos" }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.5"
  }

  user_data = fileexists("${local.talos_config_dir}/unorouter-unorouter-node12.yaml") ? file("${local.talos_config_dir}/unorouter-unorouter-node12.yaml") : null

  lifecycle {
    ignore_changes = [user_data, image, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

resource "hcloud_server" "node13" {
  name         = "unorouter-node13"
  server_type  = "cx43"
  location     = "nbg1"
  image        = data.hcloud_image.talos.id
  firewall_ids = [hcloud_firewall.node.id]
  labels       = { os = "talos" }

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.6"
  }

  user_data = fileexists("${local.talos_config_dir}/unorouter-unorouter-node13.yaml") ? file("${local.talos_config_dir}/unorouter-unorouter-node13.yaml") : null

  lifecycle {
    ignore_changes = [user_data, image, ssh_keys]
  }

  depends_on = [hcloud_network_subnet.nodes]
}
