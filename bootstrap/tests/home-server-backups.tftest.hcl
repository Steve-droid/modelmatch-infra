# Mocked plans only. No real bucket, IAM role, SNS message or Lambda invocation.
mock_provider "aws" {
  # These unrelated existing-stack data sources must still produce valid JSON for
  # provider schema validation. Real backup/teardown policy JSON is checked in the
  # refreshed AWS plan and IAM simulation, not replaced by this mock's empty policy.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}
mock_provider "aws" { alias = "us_east_1" }
mock_provider "archive" {}

run "private_versioned_destination" {
  command = plan
  assert {
    condition = (
      aws_s3_bucket.home_server_backups.force_destroy == false &&
      aws_s3_bucket_versioning.home_server_backups.versioning_configuration[0].status == "Enabled" &&
      aws_s3_bucket_ownership_controls.home_server_backups.rule[0].object_ownership == "BucketOwnerEnforced" &&
      aws_s3_bucket_server_side_encryption_configuration.home_server_backups.rule[*].apply_server_side_encryption_by_default[0].sse_algorithm == tolist(["AES256"])
    )
    error_message = "Backups require versioning, bucket ownership and encryption without force-empty deletion."
  }
  assert {
    condition = (
      aws_s3_bucket_public_access_block.home_server_backups.block_public_acls &&
      aws_s3_bucket_public_access_block.home_server_backups.block_public_policy &&
      aws_s3_bucket_public_access_block.home_server_backups.ignore_public_acls &&
      aws_s3_bucket_public_access_block.home_server_backups.restrict_public_buckets
    )
    error_message = "Every public-access block must remain enabled."
  }
  assert {
    condition     = var.killswitch_lambda_dry_run == "1"
    error_message = "Preparing backups must not re-arm automatic source teardown."
  }
}

run "reject_state_bucket_reuse" {
  command = plan
  variables {
    home_server_backup_bucket_name = "modelmatch-tfstate-957261948820"
  }
  expect_failures = [var.home_server_backup_bucket_name]
}

run "reject_ingestion_bucket_reuse" {
  command = plan
  variables {
    home_server_backup_bucket_name = "modelmatch-ingestion-sources-957261948820"
  }
  expect_failures = [var.home_server_backup_bucket_name]
}

run "reject_invalid_bucket_name" {
  command = plan
  variables {
    home_server_backup_bucket_name = "INVALID backup name"
  }
  expect_failures = [var.home_server_backup_bucket_name]
}
