resource "hcloud_firewall" "node" {
  name = "unorouter-node"

  # No inbound TCP at all. App traffic is the outbound Cloudflare tunnel, operator
  # access (ssh, kube api) is Tailscale, Teleport's direct entry is retired. Break-glass is a
  # temporary 22 rule added from the Hetzner console, then the VNC console (root password in
  # Bitwarden), then rescue mode. See bootstrap/dr/README.md "Admin plane".

  # Tailscale direct peer paths (falls back to DERP relays without it, slower).
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}
