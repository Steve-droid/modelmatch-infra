# Inputs for the bootstrap (persistent) stack — declarations only. DEFAULTLESS by rule (Roey): no
# `default`s live here. Concrete NON-SECRET values are supplied explicitly via `-var-file=dev.tfvars`
# (we do NOT rely on auto-loaded terraform.tfvars / *.auto.tfvars). Secrets never go in tfvars.

variable "aws_region" {
  description = "AWS region for all resources in this stack."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket holding Terraform remote state for both stacks."
  type        = string
}

variable "budget_limit_amount" {
  description = "Monthly AWS budget alert threshold in USD (string per the AWS Budgets API). Alerting only — AWS Budgets does not stop or cap spend."
  type        = string
}

variable "alert_email" {
  description = "Email address subscribed to the budget-alert SNS topic. Config, not a secret."
  type        = string
}

variable "ecr_repository_names" {
  description = "ECR repositories adopted into Terraform (FE / BE / agent). Imported in P5 — they predate Terraform and hold the live :1.0.0 images."
  type        = list(string)
}

variable "ingestion_bucket_name" {
  description = "S3 bucket for catalog-ingestion source docs (S5b). APP CONTRACT — must match the default of `s3_bucket` in modelmatch-backend/app/config.py; the P7 IRSA role-A policy scopes to its ARN."
  type        = string
}

variable "home_server_recovery_key_secret_name" {
  description = "Dedicated operator-only recovery-key secret name; metadata only in Terraform."
  type        = string
  validation {
    condition     = can(regex("^modelmatch/home-server/recovery-key-v[1-9][0-9]*$", var.home_server_recovery_key_secret_name))
    error_message = "Use a versioned modelmatch/home-server/recovery-key-vN name, separate from runtime app secrets."
  }
}

variable "home_server_recovery_operator_arn" {
  description = "IAM principal allowed to read the recovery key; never a home-server workload role."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", var.home_server_recovery_operator_arn))
    error_message = "Use an explicit IAM user or role ARN, not a wildcard or STS session ARN."
  }
}

# --- P34b budget kill switch (killswitch.tf) ---

variable "killswitch_lambda_dry_run" {
  description = "DRY_RUN value the kill-switch Lambda passes to the teardown build: \"1\" = plan-only (test), \"0\" = the real teardown. Flipped to \"0\" once the dry-run tests pass."
  type        = string
}

variable "killswitch_trigger_percent" {
  description = "Budget percentage (ACTUAL) that arms the teardown. Must match the ACTUAL notification threshold in budget.tf that the Lambda filters on."
  type        = number
}

variable "killswitch_build_timeout_minutes" {
  description = "CodeBuild timeout for the platform teardown build (a full destroy takes ~15 min; every internal wait is separately capped)."
  type        = number
}

variable "killswitch_log_retention_days" {
  description = "CloudWatch retention for the kill-switch Lambda + teardown build logs (the trace is a portfolio artifact)."
  type        = number
}

variable "codebuild_image" {
  description = "Curated CodeBuild image for the teardown build (awscli + git + jq built in; terraform is installed from the pinned zip)."
  type        = string
}

variable "terraform_version" {
  description = "Terraform version installed in the teardown build — pin the same version the laptop runs."
  type        = string
}

variable "terraform_sha256_linux_amd64" {
  description = "SHA256 of terraform_<version>_linux_amd64.zip from the official SHA256SUMS; the build refuses a mismatch."
  type        = string
}

variable "infra_repo_url" {
  description = "Public HTTPS clone URL of this repo — the teardown build clones it (no credential needed)."
  type        = string
}

variable "infra_repo_branch" {
  description = "Branch the teardown build checks out."
  type        = string
}
