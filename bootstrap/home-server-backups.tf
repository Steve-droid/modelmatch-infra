# E21/HM2: independent of platform/ destruction, but in Steve's existing AWS account.
# This only provisions the backup destination. HM3/HM5 own encrypted export/restore,
# scheduled uploads, retention activation and dedicated short-lived home-server identity.
data "aws_partition" "current" {}

locals {
  home_server_backup_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.home_server_backup_bucket_name}"
}

resource "aws_s3_bucket" "home_server_backups" {
  bucket        = var.home_server_backup_bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "home_server_backups" {
  bucket = aws_s3_bucket.home_server_backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "home_server_backups" {
  bucket                  = aws_s3_bucket.home_server_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "home_server_backups" {
  bucket = aws_s3_bucket.home_server_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "home_server_backups" {
  bucket = aws_s3_bucket.home_server_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "home_server_backups" {
  bucket = aws_s3_bucket.home_server_backups.id
  # No access grants here: uploads/restores require a separately authorized IAM identity.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.home_server_backup_bucket_arn, "${local.home_server_backup_bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyPlatformTeardownAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.home_server_backup_bucket_arn, "${local.home_server_backup_bucket_arn}/*"]
        Condition = { ArnEquals = { "aws:PrincipalArn" = aws_iam_role.platform_teardown.arn } }
      }
    ]
  })
}

# Deliberately no expiry rules until a restore from S3 succeeds and retention is reviewed.
# Versioning and prevent_destroy are not immutable retention or protection from account admins.
