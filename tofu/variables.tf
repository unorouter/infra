variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "operator_cidr" {
  description = "CIDR allowed to reach ssh + kube-api (your IP or tailnet range)"
  type        = string
}

variable "ssh_public_key" {
  type = string
}

variable "tailscale_authkey" {
  description = "Reusable tailnet auth key; empty = skip tailscale join"
  type        = string
  sensitive   = true
  default     = ""
}

variable "k3s_version" {
  description = "Pin like v1.33.4+k3s1; empty = stable channel"
  type        = string
  default     = ""
}

variable "location" {
  type    = string
  default = "nbg1"
}

# ARCH SWITCH: cx43 (x86 Intel, ~EUR20/mo) while Hetzner's ARM (CAX) shortage lasts
# (incident 2026-06-26, ARM-only). Flip to cax31 when CAX capacity returns, then
# destroy+apply -> restores from S3 (node is disposable). Images are multi-arch so
# either arch runs the same tags. k3s install auto-detects arch.
variable "node_type" {
  type    = string
  default = "cx43"
}
