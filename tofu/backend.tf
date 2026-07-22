# Remote state on the (prevent_destroy) Hetzner bucket -- laptop loss no longer loses state.
# Creds via AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY from .env. Ceph: no dynamodb locking;
# single-operator setup, plain state versioning on the bucket covers races.
terraform {
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
}
