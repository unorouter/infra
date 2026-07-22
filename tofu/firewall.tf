resource "hcloud_firewall" "node" {
  name = "unorouter-node"

  # :80 closed -- CF Tunnel is outbound-only (internal UIs need no inbound). Teleport ACME uses
  # TLS-ALPN-01 (on 443), not HTTP-01, so :80 is unnecessary.
  # :443 kept ONLY for Teleport (direct grey-cloud; ALPN can't tunnel). Everything else = tunnel.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.operator_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.operator_cidr]
  }

  # tailscale runs over outbound UDP 41641/3478 (no inbound rule needed; NAT traversal)
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}
