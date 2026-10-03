variable "hcloud_token" {
  type      = string
  sensitive = true
}

# Hetzner project SSH key. Talos has no SSH; Hetzner rescue mode boots with it (docs/dr.md).
variable "ssh_public_key" {
  type = string
}

variable "state_passphrase" {
  type      = string
  sensitive = true
}
