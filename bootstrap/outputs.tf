# Consumed by the platform stack's backend config and (later slices) by
# terraform_remote_state for cross-stack values (ECR URLs, bucket ARNs).
output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.tf_state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform remote-state bucket."
  value       = aws_s3_bucket.tf_state.arn
}

output "aws_region" {
  description = "Region the state bucket lives in."
  value       = var.aws_region
}
