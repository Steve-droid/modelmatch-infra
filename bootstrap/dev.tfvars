# Concrete NON-SECRET values for the bootstrap (persistent) stack.
# Passed EXPLICITLY: `terraform -chdir=bootstrap plan|apply -var-file=dev.tfvars`
# (we do not rely on auto-loaded terraform.tfvars / *.auto.tfvars — Roey's rule, predictability).
# Committed on purpose: nothing here is a secret. Secrets reach the cluster via Secrets Manager
# (ESO + IRSA), never through tfvars.

aws_region = "ap-south-1"

# --- State backend (P1) ---
state_bucket_name = "modelmatch-tfstate-832285994273"

# --- Budget + alerting (P2) ---
budget_limit_amount = "25"                      # USD/month, alert threshold only (Budgets never caps spend)
alert_email         = "stevelevit230@gmail.com" # config, not a secret

# --- ECR repos adopted into TF (P5) — hold the live :1.0.0 images ---
ecr_repository_names = ["modelmatch-backend", "modelmatch-frontend", "modelmatch-agent"]

# --- Ingestion source bucket (P6) — APP CONTRACT (matches modelmatch-backend app/config.py) ---
ingestion_bucket_name = "modelmatch-ingestion-sources"
