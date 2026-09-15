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
  bucket = "unorouter-pg-backups"

  # DR DATA: never let tofu destroy the backup bucket (CNPG backups + Vault snapshots live
  # here and must survive every node destroy). tofu destroy will error on this by design.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "pg_backups" {
  bucket = aws_s3_bucket.pg_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Loki chunks and index. Unlocked and unversioned on purpose: the compactor deletes expired
# chunks and rewrites index files, so a lock or versioning would only pile up ciphertext.
# Retention is Loki's (90 day compactor); the lifecycle expiry at 120 days, set by signed PUT
# like the others, is the safety net. Everything in it is crypt ciphertext from the gateway.
resource "aws_s3_bucket" "loki" {
  bucket = "unorouter-loki"
  lifecycle {
    prevent_destroy = true
  }
}

# new-api-sync shared state: logs/verdict-cache.json (overwritten every run) and the run
# artifacts. Versioned so an overwrite can be rolled back; unlocked because the object is
# rewritten dozens of times a day. Noncurrent versions expire by lifecycle (30 days, set by
# signed PUT like the others). Everything in it is crypt ciphertext from the gateway.
resource "aws_s3_bucket" "sync" {
  bucket = "unorouter-sync"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "sync" {
  bucket = aws_s3_bucket.sync.id
  versioning_configuration {
    status = "Enabled"
  }
}
