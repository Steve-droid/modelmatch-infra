# Monthly AWS cost budget — the financial ground-truth backstop for the whole build. It covers
# the AWS-side spend (EKS control plane + NAT + EBS + data transfer); Anthropic app-API spend is
# tracked separately on the Anthropic console, not here. Deliberately created EARLY (P2), before
# the first EKS apply, so the alert path is live before any cluster spend can start. Lives in the
# PERSISTENT bootstrap stack so it survives the daily platform/ destroy.
#
# Budgets is a global service managed via the us-east-1 endpoint; the default (ap-south-1)
# provider handles that transparently, so no alias is needed on the budget itself — only on the
# SNS topic it notifies (see sns.tf). The budget picks up default_tags like any taggable
# resource (visible in state as tags_all).
#
# Each notification has TWO delivery channels:
#   - subscriber_email_addresses: budget-native email straight from AWS Budgets. This is the
#     RELIABLE channel — these mails carry no SNS "unsubscribe" link, so Gmail's link-prefetch
#     (security scanning) can't silently deactivate the subscription the way it does for SNS
#     email subscriptions. This is what actually guarantees the alert reaches the inbox.
#   - subscriber_sns_topic_arns: the SNS topic (see sns.tf), kept for the topic/subscription
#     pattern + future programmatic fan-out (Slack/Lambda). Not relied on for email delivery.

resource "aws_budgets_budget" "monthly_cost" {
  name         = "modelmatch-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.budget_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 80% of the cap, measured against ACTUAL spend — "you've already burned this much".
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # 100% FORECASTED — AWS projects the month's run-rate and warns before you actually hit the cap.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}
