# SNS topic that receives AWS Budgets alert notifications and fans them out to email
# (and, later, Slack/Lambda if we want). The topic MUST live in us-east-1 because AWS Budgets
# is a global service whose notifications can only target a us-east-1 SNS topic — hence the
# aws.us_east_1 provider alias (see providers.tf). It is in the PERSISTENT bootstrap stack so
# cost alerting survives the daily platform/ destroy.

resource "aws_sns_topic" "budget_alerts" {
  provider = aws.us_east_1
  name     = "modelmatch-budget-alerts"
}

# Email subscription. AWS sends a confirmation email to this address; the link must be clicked
# once before any message is delivered (state stays "PendingConfirmation" until then).
resource "aws_sns_topic_subscription" "budget_alerts_email" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# The topic's default policy only lets the account root publish. AWS Budgets publishes as the
# service principal budgets.amazonaws.com, so we must explicitly grant it SNS:Publish on this
# topic — scoped to our account (aws:SourceAccount) AND to our budgets (aws:SourceArn) for
# least privilege, per AWS's Budgets-to-SNS policy guidance. Budgets ARNs are global, so the
# region segment is empty: arn:aws:budgets::<account>:*.
data "aws_iam_policy_document" "budget_alerts_topic" {
  statement {
    sid    = "AllowBudgetsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.budget_alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:budgets::${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_sns_topic_policy" "budget_alerts" {
  provider = aws.us_east_1
  arn      = aws_sns_topic.budget_alerts.arn
  policy   = data.aws_iam_policy_document.budget_alerts_topic.json
}

# Account id for the topic-policy SourceAccount condition (avoids hardcoding 832285994273).
data "aws_caller_identity" "current" {}
