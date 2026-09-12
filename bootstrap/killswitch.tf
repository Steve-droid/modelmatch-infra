# P34b — Budget kill switch: Budgets 90% ACTUAL → SNS → Lambda → CodeBuild `terraform destroy` platform/.
#
# Why it exists: the account is on the PAID plan, so once the ~$120 credit is gone the card is charged,
# and a budget alone only emails. This turns the 90% ACTUAL notification (budget.tf) into an unattended
# teardown of the EPHEMERAL platform/ stack. bootstrap/ (state, ECR, budget, this switch) and jenkins/
# are never touched — the build runs scripts/teardown-platform.sh, which only destroys platform/.
#
#   aws_budgets_budget (90% ACTUAL) ──► SNS modelmatch-budget-alerts (us-east-1)
#                                          ├─► email (human trace, unchanged)
#                                          └─► Lambda modelmatch-budget-killswitch (us-east-1)
#                                                 │ filters: ACTUAL + ≥90% (text) OR Budgets API ratio ≥ 0.9
#                                                 ▼ codebuild:StartBuild (cross-region)
#                                       CodeBuild modelmatch-platform-teardown (ap-south-1)
#                                          clones public modelmatch-infra@main → scripts/teardown-platform.sh
#                                          DRY_RUN default 1 (plan only); the Lambda / P47 pass 0 explicitly
#                                                 └─► EventBridge build-state → SNS → email
#
# Regions: the topic must be us-east-1 (Budgets rule) and an SNS `lambda` subscription must be in the
# topic's region, hence the Lambda uses the aws.us_east_1 alias and starts the build cross-region.
# Same-day dry runs are the test path; live-fire is the switch itself or the P47 final teardown.

locals {
  killswitch_lambda_name = "modelmatch-budget-killswitch"
  teardown_project_name  = "modelmatch-platform-teardown"
}

# =====================================================================================================
# 1. The trigger — Lambda in us-east-1 subscribed to the budget topic
# =====================================================================================================

data "archive_file" "killswitch" {
  type        = "zip"
  source_file = "${path.module}/lambda/killswitch.py"
  output_path = "${path.module}/.terraform/lambda-killswitch.zip" # .terraform/ is gitignored
}

data "aws_iam_policy_document" "killswitch_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "killswitch_lambda" {
  name               = local.killswitch_lambda_name
  assume_role_policy = data.aws_iam_policy_document.killswitch_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "killswitch_lambda_logs" {
  role       = aws_iam_role.killswitch_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least privilege: start THIS build project only + read THIS budget (the API ground-truth check).
data "aws_iam_policy_document" "killswitch_lambda" {
  statement {
    sid       = "StartTheTeardownBuildOnly"
    actions   = ["codebuild:StartBuild"]
    resources = [aws_codebuild_project.platform_teardown.arn]
  }
  statement {
    sid       = "ReadTheBudgetForGroundTruth"
    actions   = ["budgets:ViewBudget"]
    resources = ["arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/${aws_budgets_budget.monthly_cost.name}"]
  }
}

resource "aws_iam_role_policy" "killswitch_lambda" {
  name   = "start-teardown-build"
  role   = aws_iam_role.killswitch_lambda.id
  policy = data.aws_iam_policy_document.killswitch_lambda.json
}

resource "aws_cloudwatch_log_group" "killswitch_lambda" {
  provider          = aws.us_east_1
  name              = "/aws/lambda/${local.killswitch_lambda_name}"
  retention_in_days = var.killswitch_log_retention_days
}

resource "aws_lambda_function" "killswitch" {
  provider      = aws.us_east_1
  function_name = local.killswitch_lambda_name
  description   = "Budget kill switch: on the ${var.killswitch_trigger_percent}% ACTUAL alert, start the platform teardown build in ${var.aws_region}"
  role          = aws_iam_role.killswitch_lambda.arn
  runtime       = "python3.13"
  handler       = "killswitch.handler"
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.killswitch.output_path
  source_code_hash = data.archive_file.killswitch.output_base64sha256

  environment {
    variables = {
      CODEBUILD_PROJECT = aws_codebuild_project.platform_teardown.name
      CODEBUILD_REGION  = var.aws_region
      BUDGET_NAME       = aws_budgets_budget.monthly_cost.name
      BUDGET_LIMIT_USD  = var.budget_limit_amount
      TRIGGER_PERCENT   = tostring(var.killswitch_trigger_percent)
      ACCOUNT_ID        = data.aws_caller_identity.current.account_id
      DRY_RUN           = var.killswitch_lambda_dry_run # "1" while testing, "0" = armed
    }
  }

  depends_on = [aws_cloudwatch_log_group.killswitch_lambda, aws_iam_role_policy_attachment.killswitch_lambda_logs]
}

resource "aws_lambda_permission" "killswitch_from_budget_topic" {
  provider      = aws.us_east_1
  statement_id  = "AllowBudgetAlertsTopicToInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.killswitch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget_alerts.arn
}

# Second subscriber on the existing budget topic (the email subscription in sns.tf stays untouched).
resource "aws_sns_topic_subscription" "budget_alerts_killswitch" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.killswitch.arn
}

# =====================================================================================================
# 2. The actuator — CodeBuild project in ap-south-1 that runs scripts/teardown-platform.sh
# =====================================================================================================

data "aws_iam_policy_document" "platform_teardown_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    # Confused-deputy guard: only CodeBuild resources in THIS account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "platform_teardown" {
  name               = "${local.teardown_project_name}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.platform_teardown_assume.json
}

# Conscious trade-off (documented in the HLD): `terraform destroy` on platform/ touches VPC, EKS, IAM,
# EC2, ELB and the S3 state bucket — the same authority the laptop has. A hand-built least-privilege
# policy cannot be proven by a dry run (plan -destroy never exercises Delete permissions), and one
# missing action would leave a half-destroyed platform at the exact moment the budget is exhausted.
# So: AdministratorAccess, fenced by the explicit Denies below.
resource "aws_iam_role_policy_attachment" "platform_teardown_admin" {
  role       = aws_iam_role.platform_teardown.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

data "aws_iam_policy_document" "platform_teardown_guardrails" {
  statement {
    sid       = "DenyAccessToHomeServerRecoveryKey"
    effect    = "Deny"
    actions   = ["secretsmanager:*"]
    resources = [local.home_server_recovery_key_arn_pattern]
  }
  # Nothing outside our two regions (IAM/STS global calls carry aws:RequestedRegion = us-east-1).
  statement {
    sid       = "DenyOutsideOurRegions"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region, "us-east-1"]
    }
  }
  # The persistent buckets can never be deleted by the switch (state + ingestion sources).
  statement {
    sid       = "DenyDeletingPersistentBuckets"
    effect    = "Deny"
    actions   = ["s3:DeleteBucket", "s3:DeleteBucketPolicy"]
    resources = [aws_s3_bucket.tf_state.arn, aws_s3_bucket.ingestion.arn]
  }
  # The switch cannot dismantle bootstrap/ — images, the budget, the alert topic — or itself.
  statement {
    sid    = "DenyTouchingBootstrapOrItself"
    effect = "Deny"
    actions = [
      "ecr:DeleteRepository", "ecr:BatchDeleteImage",
      "budgets:ModifyBudget", "budgets:DeleteBudget",
      "sns:DeleteTopic", "sns:Unsubscribe", "sns:SetTopicAttributes",
      "lambda:DeleteFunction", "lambda:UpdateFunctionConfiguration", "lambda:UpdateFunctionCode",
      "codebuild:DeleteProject", "codebuild:UpdateProject",
    ]
    resources = ["*"]
  }
  # The persistent jenkins/ stack (stack=jenkins tag) is out of bounds for the destructive EC2 calls.
  statement {
    sid       = "DenyDestroyingJenkins"
    effect    = "Deny"
    actions   = ["ec2:TerminateInstances", "ec2:StopInstances", "ec2:DeleteVolume", "ec2:DetachVolume", "ec2:ReleaseAddress", "ec2:DisassociateAddress"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/stack"
      values   = ["jenkins"]
    }
  }
}

resource "aws_iam_role_policy" "platform_teardown_guardrails" {
  name   = "guardrails"
  role   = aws_iam_role.platform_teardown.id
  policy = data.aws_iam_policy_document.platform_teardown_guardrails.json
}

resource "aws_cloudwatch_log_group" "platform_teardown" {
  name              = "/aws/codebuild/${local.teardown_project_name}"
  retention_in_days = var.killswitch_log_retention_days
}

resource "aws_codebuild_project" "platform_teardown" {
  name                   = local.teardown_project_name
  description            = "Tears down the ephemeral platform/ stack without cluster auth (budget kill switch + P47 final teardown). DRY_RUN=1 by default."
  service_role           = aws_iam_role.platform_teardown.arn
  build_timeout          = var.killswitch_build_timeout_minutes
  concurrent_build_limit = 1 # the 80%/90% alerts can land together — never two teardowns at once

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # Fail-safe default: a stray console "Start build" only plans. The Lambda and the P47 command
    # override DRY_RUN explicitly.
    environment_variable {
      name  = "DRY_RUN"
      value = "1"
    }
    environment_variable {
      name  = "TF_VERSION"
      value = var.terraform_version
    }
    environment_variable {
      name  = "TF_SHA256"
      value = var.terraform_sha256_linux_amd64
    }
  }

  # Public repo over HTTPS — no source credential, no token in state (same pattern as ArgoCD's gitops read).
  source {
    type            = "GITHUB"
    location        = var.infra_repo_url
    git_clone_depth = 1
    buildspec       = "scripts/teardown-buildspec.yml"
  }
  source_version = var.infra_repo_branch

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.platform_teardown.name
      stream_name = "teardown"
    }
  }
}

# =====================================================================================================
# 3. The human trace — build state changes → SNS → email (ap-south-1)
# =====================================================================================================

resource "aws_sns_topic" "killswitch_events" {
  name = "modelmatch-killswitch-events"
}

# No email subscription on purpose (decided 2026-09-07). An SNS email subscription carries an
# UNAUTHENTICATED unsubscribe link in every mail, and a link-prefetching mail client follows it: the
# first one died seconds after confirmation. Denying SNS:Unsubscribe in the topic policy is impossible
# (out of topic-policy scope) and the authenticated-unsubscribe route needs a CLI confirm with the
# emailed token — not worth it for a nice-to-have. The human trace is the budget-native 90% email
# (budget.tf) + CloudWatch Logs; this topic stays as the EventBridge target for a future Slack/Lambda
# subscriber.

data "aws_iam_policy_document" "killswitch_events_topic" {
  statement {
    sid    = "AllowEventBridgeToPublish"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.killswitch_events.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.platform_teardown_state.arn]
    }
  }
}

resource "aws_sns_topic_policy" "killswitch_events" {
  arn    = aws_sns_topic.killswitch_events.arn
  policy = data.aws_iam_policy_document.killswitch_events_topic.json
}

resource "aws_cloudwatch_event_rule" "platform_teardown_state" {
  name        = "${local.teardown_project_name}-state"
  description = "Email every state change of the platform teardown build (started / succeeded / failed / stopped)."
  event_pattern = jsonencode({
    source        = ["aws.codebuild"]
    "detail-type" = ["CodeBuild Build State Change"]
    detail = {
      "project-name" = [aws_codebuild_project.platform_teardown.name]
      "build-status" = ["IN_PROGRESS", "SUCCEEDED", "FAILED", "STOPPED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "platform_teardown_state_sns" {
  rule = aws_cloudwatch_event_rule.platform_teardown_state.name
  arn  = aws_sns_topic.killswitch_events.arn

  input_transformer {
    input_paths = {
      status  = "$.detail.build-status"
      project = "$.detail.project-name"
      build   = "$.detail.build-id"
      time    = "$.time"
    }
    input_template = "\"ModelMatch platform teardown: <status> (<project>) at <time>. Build: <build>. Logs: CloudWatch /aws/codebuild/${local.teardown_project_name}. Mode (DRY_RUN) is printed in the build log's preflight step.\""
  }
}
