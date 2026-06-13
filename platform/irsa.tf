# P7: IRSA roles — in-cluster workloads get scoped AWS access through the cluster OIDC provider (P4)
# with NO static keys. Two roles, two ServiceAccounts:
#   role A = the backend pod (app/modelmatch-backend) -> Bedrock Nova (Converse/InvokeModel) + the
#            ingestion S3 bucket
#   role B = External Secrets Operator (external-secrets/external-secrets) -> Secrets Manager (the
#            app secret path only)
# ARNs are BUILT from data sources (account/partition/region) so nothing hardcodes the account id —
# only names/ids live in dev.tfvars. The ingestion-bucket ARN comes from the persistent bootstrap
# stack via terraform_remote_state (the app contract, not duplicated as a literal).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# First cross-stack read in platform/: the bootstrap stack's outputs (the ingestion bucket ARN from
# P6). Backend block literals must stay in sync with bootstrap/backend.tf by hand (CLAUDE.md).
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "modelmatch-tfstate-832285994273"
    key    = "bootstrap/terraform.tfstate"
    region = "ap-south-1"
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Account-specific inference-profile ARNs the backend actually invokes (verified live in
  # ap-south-1, 2026-06-13): Nova Lite via the APAC profile, Nova 2-Lite via the GLOBAL profile.
  bedrock_inference_profile_arns = [
    for id in var.bedrock_inference_profile_ids :
    "arn:${local.partition}:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${id}"
  ]

  # The foundation models those profiles route to. The REGION segment is wildcarded (apac/global
  # cross-region routing reaches several regions — the global profile is even region-less), while
  # the MODEL is pinned exactly. Least-privilege on which model; tolerant of added routing regions.
  bedrock_foundation_model_arns = [
    for id in var.bedrock_foundation_model_ids :
    "arn:${local.partition}:bedrock:*::foundation-model/${id}"
  ]

  ingestion_bucket_arn = data.terraform_remote_state.bootstrap.outputs.ingestion_bucket_arn

  # The single app secret ESO reads. The -?????? glob matches Secrets Manager's random 6-char
  # suffix, so the policy is valid before the secret is created (P12) and scopes to just this path.
  app_secret_arn = "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.app_secret_name}-??????"
}

# ---- Role A: backend pod -> Bedrock Nova + ingestion S3 bucket --------------
# bedrock:InvokeModel covers the Converse API the backend uses (nothing streams today, so no
# InvokeModelWithResponseStream). Invoking THROUGH an inference profile is evaluated against BOTH the
# profile ARN and the foundation-model ARNs it routes to — so two statements, least-privilege:
#   (1) the two approved profile ARNs are invokable directly;
#   (2) the foundation models are invokable ONLY when the call is routed through one of those
#       profiles, enforced by the bedrock:InferenceProfileArn condition — never as bare models.
# S3: GetObject/PutObject only — the BlobStore seam never lists (idempotency is DB content-hash), so
# no s3:ListBucket.
data "aws_iam_policy_document" "backend" {
  statement {
    sid       = "InvokeNovaProfiles"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = local.bedrock_inference_profile_arns
  }

  statement {
    sid       = "InvokeNovaModelsViaProfile"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = local.bedrock_foundation_model_arns

    # FM access is scoped to requests that go through the two approved profiles, not direct.
    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = local.bedrock_inference_profile_arns
    }
  }

  statement {
    sid       = "IngestionObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.ingestion_bucket_arn}/*"]
  }
}

module "irsa_backend" {
  source = "../modules/iam-irsa"

  role_name         = "${var.cluster_name}-backend-irsa"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer_url
  namespace         = var.backend_namespace
  service_account   = var.backend_service_account
  policy_json       = data.aws_iam_policy_document.backend.json
}

# ---- Role B: External Secrets Operator -> Secrets Manager -------------------
# Only secretsmanager:GetSecretValue, scoped to the one app secret path (the platform-secret set:
# JWT_SECRET + DB password + LLM-cap config — NOT per-project tokens or BYOK keys, which never
# touch AWS). ESO assumes this via its controller SA (P12 wires the SecretStore).
data "aws_iam_policy_document" "eso" {
  statement {
    sid       = "ReadAppSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.app_secret_arn]
  }
}

module "irsa_eso" {
  source = "../modules/iam-irsa"

  role_name         = "${var.cluster_name}-eso-irsa"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer_url
  namespace         = var.eso_namespace
  service_account   = var.eso_service_account
  policy_json       = data.aws_iam_policy_document.eso.json
}
