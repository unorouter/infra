# Pre-created here because Barman Cloud >=3.16 no longer auto-creates buckets.
resource "aws_s3_bucket" "pg_backups" {
  provider = aws.hetzner_s3
  bucket   = "unorouter-pg-backups"
}

resource "aws_s3_bucket_versioning" "pg_backups" {
  provider = aws.hetzner_s3
  bucket   = aws_s3_bucket.pg_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

/* Ceph-incompatible: aws provider hangs on lifecycle PUT (Hetzner RadosGW).
   Set via CLI instead (see bootstrap/dr/README). Bucket+versioning stay tofu-managed.
# Expiry LONGER than Barman retention (30d) so retention deletes first; this is the safety net.
resource "aws_s3_bucket_lifecycle_configuration" "pg_backups" {
  provider = aws.hetzner_s3
  bucket   = aws_s3_bucket.pg_backups.id

  # Ceph has no size-based transition tiers; disable the aws>=5.70 default probe.
  transition_default_minimum_object_size = "varies_by_storage_class"

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 35
    }
  }
}
*/
