# S3 bucket for catalog-ingestion (#3 / S5b) source documents: the backend's blob_store seam
# writes the unstructured model/benchmark source bytes here (provenance copy) before Nova
# extracts them into structured catalog rows. The bucket name is an APP CONTRACT — it is the
# default of `s3_bucket` in modelmatch-backend/app/config.py:111, and the P7 IRSA role-A policy
# scopes s3 access to this bucket's ARN (output below, read via terraform_remote_state).
#
# Lives in the PERSISTENT bootstrap stack: source docs (and the catalog provenance trail) must
# survive the daily platform `destroy`. Mirrors the state-bucket pattern in main.tf — private +
# AES256 at rest. No versioning (source docs are content-hash idempotent in S5b), no
# prevent_destroy (re-ingestible from source URLs; the daily-destroy exclusion comes from being
# in bootstrap/, not from a lifecycle guard).

resource "aws_s3_bucket" "ingestion" {
  bucket = var.ingestion_bucket_name
}

# Encrypt source docs at rest (match the state bucket; in-cluster reaches this via IRSA, no keys).
resource "aws_s3_bucket_server_side_encryption_configuration" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Source docs must never be public.
resource "aws_s3_bucket_public_access_block" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
