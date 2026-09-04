variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "operator_cidr" {
  description = "CIDR allowed to reach kube-api :6443 (ssh is world-open, key-only)"
  type        = string
}

variable "ssh_public_key" {
  type = string
}

variable "k3s_version" {
  description = "Pin like v1.33.4+k3s1; empty = stable channel"
  type        = string
  default     = ""
}

# Defaults MUST match the live node1 (fsn1/cx33, see .env): location/node_type are NOT in
# ignore_changes, so a plan run with stale defaults proposes destroy+recreate of the
# production control plane.
variable "location" {
  type    = string
  default = "fsn1"
}

# x86 while Hetzner's ARM (CAX) shortage lasts (incident 2026-06-26, ARM-only). Flip to
# cax31 when CAX capacity returns, then destroy+apply -> restores from S3 (node is
# disposable). Images are multi-arch so either arch runs the same tags.
variable "node_type" {
  type    = string
  default = "cx33"
}

variable "k3s_token" {
  description = "cluster join token (node1 /var/lib/rancher/k3s/server/token); also in OpenBao"
  type      = string
  sensitive = true
  validation {
    condition     = length(var.k3s_token) > 0
    error_message = "k3s_token must be set (empty token = confusing join failure at cloud-init time)."
  }
}
