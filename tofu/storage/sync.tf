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
