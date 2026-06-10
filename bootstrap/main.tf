# Terraform remote-state backend store: the S3 bucket that holds the state for BOTH stacks
# (bootstrap/terraform.tfstate + platform/terraform.tfstate). This stack is PERSISTENT — it is
# never part of the daily `apply`/`destroy` ritual, so prevent_destroy guards the bucket.
#
# State locking is S3-native (`use_lockfile = true` in each backend.tf, Terraform >= 1.10) —
# no DynamoDB table required.

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name

  # The bucket stores all Terraform state — losing it would orphan every managed resource.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning lets us recover a previous state file if an apply corrupts it.
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest (state can contain sensitive values).
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State must never be public.
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
