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

# Exposed for future fan-out (Slack/Lambda subscribers) and so platform/ could notify it later.
output "budget_alerts_topic_arn" {
  description = "ARN of the SNS topic that receives AWS Budgets alerts (us-east-1)."
  value       = aws_sns_topic.budget_alerts.arn
}

# Re-exported from the ECR module so platform/ and gitops can resolve image locations via
# terraform_remote_state on this bootstrap stack (no hardcoded registry URLs).
output "ecr_repository_urls" {
  description = "Map of ECR repository name -> repository URL (no tag)."
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "Map of ECR repository name -> repository ARN."
  value       = module.ecr.repository_arns
}
