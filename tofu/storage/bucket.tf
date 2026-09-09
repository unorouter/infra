# Hetzner Object Storage has no at-rest encryption; the in-cluster s3-gateway encrypts client
# side (rclone crypt) for every writer that needs it. Object Lock can only be enabled
# at creation and COMPLIANCE retention cannot be ended early: writers only insert, the bucket
# lifecycle expires (set by CLI, the aws provider hangs on lifecycle PUT against RadosGW).
# Velero is the one unlocked bucket: Kopia must delete session markers and rewrite indexes, so
# versioning plus NoncurrentDays is its protection.
resource "aws_s3_bucket" "backups" {
  bucket              = "unorouter-backups"
  object_lock_enabled = true
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 30
    }
  }
  depends_on = [aws_s3_bucket_versioning.backups]
}

resource "aws_s3_bucket" "evidence" {
  bucket              = "unorouter-evidence"
  object_lock_enabled = true
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 30
    }
  }
  depends_on = [aws_s3_bucket_versioning.evidence]
}

# Logs: audit streams, incidents, PAT archive, Teleport recordings. Replaces unorouter-evidence
# (a locked bucket cannot be renamed); that one drains by lifecycle and leaves this file empty.
resource "aws_s3_bucket" "logs" {
  bucket              = "unorouter-logs"
  object_lock_enabled = true
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 90
    }
  }
  depends_on = [aws_s3_bucket_versioning.logs]
}

resource "aws_s3_bucket" "velero" {
  bucket = "unorouter-velero"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Pre-created here because Barman Cloud >=3.16 no longer auto-creates buckets.
resource "aws_s3_bucket" "pg_backups" {
  bucket   = "unorouter-pg-backups"

  # DR DATA: never let tofu destroy the backup bucket (CNPG backups + Vault snapshots live
  # here and must survive every node destroy). tofu destroy will error on this by design.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "pg_backups" {
  bucket   = aws_s3_bucket.pg_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

/* Ceph-incompatible: aws provider hangs on lifecycle PUT (Hetzner RadosGW).
   Set via CLI instead (see bootstrap/dr/README). Bucket+versioning stay tofu-managed.
# Expiry LONGER than Barman retention (30d) so retention deletes first; this is the safety net.
resource "aws_s3_bucket_lifecycle_configuration" "pg_backups" {
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
