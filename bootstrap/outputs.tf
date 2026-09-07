# Cross-stack outputs: the platform stack (and later CI / gitops) read these via a
# `terraform_remote_state` data source pointed at this bootstrap state — ECR URLs/ARNs, the
# state-bucket name/ARN, the budget topic.
#
# NOTE: the platform `backend "s3"` block does NOT read these. A backend block accepts only
# literals (no variables, no remote_state), so bucket/key/region are hardcoded there and kept
# in sync across the two backend.tf files by hand (see modelmatch-infra/CLAUDE.md). These
# outputs feed the `terraform_remote_state` data source (which can take config) and `terraform
# output` for humans/scripts — not the backend block.
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

# Ingestion bucket (P6). Read by platform/ via terraform_remote_state so the P7 IRSA role-A
# policy can scope s3 access to this exact ARN — the app contract, not duplicated as a literal.
output "ingestion_bucket_name" {
  description = "Name of the S3 bucket holding catalog-ingestion source docs (S5b)."
  value       = aws_s3_bucket.ingestion.id
}

output "ingestion_bucket_arn" {
  description = "ARN of the ingestion bucket — scoped into the P7 IRSA role-A policy."
  value       = aws_s3_bucket.ingestion.arn
}

# --- P34b budget kill switch (killswitch.tf) ---
output "killswitch_codebuild_project" {
  description = "CodeBuild project that tears down platform/ (the budget kill switch; also the P47 final teardown)."
  value       = aws_codebuild_project.platform_teardown.name
}

output "killswitch_lambda_arn" {
  description = "ARN of the us-east-1 Lambda subscribed to the budget topic (filters the 90% ACTUAL alert, starts the build)."
  value       = aws_lambda_function.killswitch.arn
}

output "killswitch_events_topic_arn" {
  description = "SNS topic (ap-south-1) that emails the teardown build's state changes."
  value       = aws_sns_topic.killswitch_events.arn
}

output "killswitch_final_teardown_cmd" {
  description = "P47: the real teardown, on demand (DRY_RUN=0 must be passed explicitly — the project default is a plan-only dry run)."
  value       = "aws codebuild start-build --region ${var.aws_region} --project-name ${aws_codebuild_project.platform_teardown.name} --environment-variables-override name=DRY_RUN,value=0,type=PLAINTEXT"
}
