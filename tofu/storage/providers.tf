terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Hetzner Object Storage (Ceph/RadosGW) via the aws S3 provider.
provider "aws" {
  region     = "fsn1"
  access_key = var.s3_access_key
  secret_key = var.s3_secret_key

  skip_credentials_validation = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    s3 = "https://fsn1.your-objectstorage.com"
  }
}
