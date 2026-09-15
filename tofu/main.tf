terraform {
  required_version = ">= 1.7"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state on the (prevent_destroy) Hetzner bucket: laptop loss does not lose state.
  # Creds via AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY from .env. Ceph: no dynamodb locking;
  # single-operator setup, plain state versioning on the bucket covers races.
  backend "s3" {
    bucket                      = "unorouter-pg-backups"
    key                         = "tofu/node.tfstate"
    region                      = "fsn1"
    endpoints                   = { s3 = "https://fsn1.your-objectstorage.com" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }

  # Client-side state encryption: the state holds the Hetzner token, the S3 credential and
  # every node and bucket detail, and the bucket has no at-rest encryption. Passphrase:
  # OpenBao secret/tofu state_passphrase, mirrored in .env as TF_VAR_state_passphrase.
  # enforced refuses plaintext state.
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

provider "hcloud" {
  token = var.hcloud_token
}

# Hetzner Object Storage (Ceph/RadosGW) through the aws S3 provider; the credential is the
# same AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY the backend reads.
provider "aws" {
  region = "fsn1"

  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    s3 = "https://fsn1.your-objectstorage.com"
  }
}
