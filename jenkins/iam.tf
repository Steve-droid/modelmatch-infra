# The Jenkins instance-role permission policy — the box's ONLY AWS identity (no static keys). Three
# concerns, least-privilege:
#   1. Bedrock InvokeModel on the 2 Nova surfaces (the e2e-live E2E path, P18) — mirrors platform IRSA
#      role A EXACTLY: the inference profiles are invokable directly; the foundation models only when
#      the call is routed THROUGH one of those profiles (the bedrock:InferenceProfileArn condition).
#   2. ECR push to the 3 ModelMatch repos (Build/Publish stages) — repo ARNs come from the persistent
#      bootstrap stack via terraform_remote_state, never hardcoded. GetAuthorizationToken is account-
#      wide (no resource-level support).
#   3. Read the pipeline credentials under modelmatch-jenkins-* (the Credentials Provider plugin) —
#      GetSecretValue scoped to that prefix; ListSecrets is account-wide (AWS gives it no resource
#      scoping) so the plugin can discover the secrets.
# ARNs are BUILT from data sources (account/partition) — nothing hardcodes the account id.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Cross-stack read: the bootstrap stack's ECR repository ARNs (P5). Backend-block literals must stay
# in sync with bootstrap/backend.tf by hand (CLAUDE.md). Mirrors platform/irsa.tf's pattern.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "modelmatch-tfstate-957261948820"
    key    = "bootstrap/terraform.tfstate"
    region = "ap-south-1"
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  bedrock_inference_profile_arns = [
    for id in var.bedrock_inference_profile_ids :
    "arn:${local.partition}:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${id}"
  ]

  # Region wildcarded (apac/global cross-region routing); model pinned exactly. Same shape as role A.
  bedrock_foundation_model_arns = [
    for id in var.bedrock_foundation_model_ids :
    "arn:${local.partition}:bedrock:*::foundation-model/${id}"
  ]

  # All three ModelMatch ECR repos (backend/frontend/agent) — the push targets.
  ecr_repository_arns = values(data.terraform_remote_state.bootstrap.outputs.ecr_repository_arns)

  # The pipeline-credential prefix. We use a FLAT, slash-free prefix (modelmatch-jenkins-*) because the
  # AWS Secrets Manager Credentials Provider plugin forbids "/" in a credential ID — the secret NAME
  # becomes the Jenkins credential ID, and the plugin docs require it to match [a-zA-Z0-9_.-]+. The
  # trailing "-*" covers both the per-credential name and Secrets Manager's own random 6-char suffix,
  # so GetSecretValue matches modelmatch-jenkins-<name>-<6char>. A least-privilege namespace, distinct
  # from the app's modelmatch/app secret (which ESO reads — slashes are fine there).
  jenkins_secrets_arn_glob = "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.jenkins_secret_prefix}-*"
}

data "aws_iam_policy_document" "jenkins_instance" {
  # 1. Bedrock — invoke the two approved inference profiles directly.
  statement {
    sid       = "InvokeNovaProfiles"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = local.bedrock_inference_profile_arns
  }

  # 1b. Bedrock — the foundation models, only when routed through one of those profiles.
  statement {
    sid       = "InvokeNovaModelsViaProfile"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = local.bedrock_foundation_model_arns

    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = local.bedrock_inference_profile_arns
    }
  }

  # 2. ECR — the auth token is account-wide (no resource scoping available).
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 2b. ECR — push (and pull, for cache) + describe scoped to the 3 ModelMatch repos.
  # DescribeImages: the agent pipeline (Jenkinsfile.agent) reads a tag's remote digest back via
  # `aws ecr describe-images` to verify the SAME image landed in ECR + Docker Hub (the cross-registry
  # same-digest contract). The backend pipeline reads digests via `docker manifest inspect`, so it
  # never needed this — only the agent's publish path does.
  statement {
    sid    = "EcrPushAndDescribe"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = local.ecr_repository_arns
  }

  # 3. Secrets Manager — read the pipeline credentials under modelmatch-jenkins-*.
  statement {
    sid       = "ReadJenkinsPipelineSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.jenkins_secrets_arn_glob]
  }

  # 3b. The Credentials Provider plugin lists secrets to discover them; ListSecrets has no
  # resource-level scoping in AWS, so it must be "*". Listing names is low-sensitivity; the plugin is
  # configured to filter to the modelmatch-jenkins- prefix.
  statement {
    sid       = "ListSecretsForPlugin"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}
