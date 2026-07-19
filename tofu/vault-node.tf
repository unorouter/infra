# Dedicated secrets node: Vault CE (BUSL, free self-hosted; OpenBao = API-identical drop-in).
# Vault API (8200) listens ONLY on the private network; hcloud firewalls don't apply to
# private traffic, so the public interface simply has no 8200 rule.
resource "hcloud_firewall" "vault" {
  name = "saas-vault"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.operator_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "vault1" {
  name         = "saas-vault1"
  server_type  = "cax11"
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.vault.id]

  network {
    network_id = hcloud_network.cluster.id
    ip         = "10.100.1.2"
  }

  user_data = templatefile("${path.module}/cloud-init-vault.yaml.tftpl", {
    tailscale_authkey = var.tailscale_authkey
  })

  depends_on = [hcloud_network_subnet.nodes]
}
