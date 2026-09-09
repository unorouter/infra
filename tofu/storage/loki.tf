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
