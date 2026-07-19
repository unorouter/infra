terraform {
  required_version = ">= 1.7"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# Hetzner Object Storage speaks S3; bucket managed via aws provider pointed at it.
# S3 credentials must be created ONCE in the Hetzner Cloud Console (not API-creatable).
provider "aws" {
  alias      = "hetzner_s3"
  region     = "fsn1"
  access_key = var.s3_access_key
  secret_key = var.s3_secret_key

  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  endpoints {
    s3 = "https://fsn1.your-objectstorage.com"
  }
}
