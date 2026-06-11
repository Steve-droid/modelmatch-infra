variable "aws_region" {
  description = "AWS region for all resources in this stack."
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket holding Terraform remote state for both stacks."
  type        = string
  default     = "modelmatch-tfstate-832285994273"
}

variable "budget_limit_amount" {
  description = "Monthly AWS budget alert threshold in USD (string per the AWS Budgets API). Alerting only — AWS Budgets does not stop or cap spend."
  type        = string
  default     = "25"
}

variable "alert_email" {
  description = "Email address subscribed to the budget-alert SNS topic. Config, not a secret."
  type        = string
  default     = "stevelevit230@gmail.com"
}

variable "ecr_repository_names" {
  description = "ECR repositories adopted into Terraform (FE / BE / agent). Imported in P5 — they predate Terraform and hold the live :1.0.0 images."
  type        = list(string)
  default     = ["modelmatch-backend", "modelmatch-frontend", "modelmatch-agent"]
}

variable "ingestion_bucket_name" {
  description = "S3 bucket for catalog-ingestion source docs (S5b). APP CONTRACT — must match the default of `s3_bucket` in modelmatch-backend/app/config.py; the P7 IRSA role-A policy scopes to its ARN."
  type        = string
  default     = "modelmatch-ingestion-sources"
}
