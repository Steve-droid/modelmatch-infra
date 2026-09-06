# Concrete NON-SECRET values for the bootstrap (persistent) stack.
# Passed EXPLICITLY: `terraform -chdir=bootstrap plan|apply -var-file=dev.tfvars`
# (we do not rely on auto-loaded terraform.tfvars / *.auto.tfvars — Roey's rule, predictability).
# Committed on purpose: nothing here is a secret. Secrets reach the cluster via Secrets Manager
# (ESO + IRSA), never through tfvars.

aws_region = "ap-south-1"

# --- State backend (P1) ---
state_bucket_name = "modelmatch-tfstate-957261948820"

# --- Budget + alerting (P2) ---
budget_limit_amount = "110"                     # USD/month, alert threshold only (Budgets never caps spend)
alert_email         = "stevelevit230@gmail.com" # config, not a secret

# --- ECR repos (P5 adopted in the old account; P32 creates them fresh in 957261948820) ---
ecr_repository_names = ["modelmatch-backend", "modelmatch-frontend", "modelmatch-agent"]

# --- Ingestion source bucket (P6) — APP CONTRACT: the backend reads it from S3_BUCKET (gitops values).
# Renamed with the account suffix at P32 (2026-09-06): the bare name was still held by the closed
# bootcamp account (AWS keeps a closed account's resources ~90 days) → BucketAlreadyExists. ---
ingestion_bucket_name = "modelmatch-ingestion-sources-957261948820"
