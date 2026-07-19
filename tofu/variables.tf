variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
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
  default = "fsn1"
}

variable "node_type" {
  type    = string
  default = "cax31"
}
