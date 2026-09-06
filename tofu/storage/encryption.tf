# Client-side state encryption (OpenTofu >= 1.7). The state holds the Hetzner API token,
# the k3s join token and every node detail, and it lives in a bucket with no at-rest
# encryption, so it is encrypted before it leaves this machine. Passphrase: OpenBao
# secret/tofu state_passphrase, mirrored in .env as TF_VAR_state_passphrase. Migrated
# 2026-09-06 with a temporary unencrypted fallback; enforced now refuses plaintext state.
variable "state_passphrase" {
  type      = string
  sensitive = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.passphrase
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
