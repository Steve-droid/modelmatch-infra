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
#
# Credits (Phase 2, 2026-09-06): the account is on the PAID plan with ~$120 of Free Tier credits
# (expire 2027-06-30). By default a cost budget nets credits out (include_credit = true), so while
# the credit absorbs charges the tracked "actual" spend would sit near $0 and NO threshold would
# fire until we were ~$100 out of pocket. cost_types below tracks GROSS usage instead, so the
# budget measures what the platform actually burns regardless of who pays for it.

resource "aws_budgets_budget" "monthly_cost" {
  name         = "modelmatch-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.budget_limit_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Track gross usage: do not let applied credits (or refunds) lower the measured spend.
  cost_types {
    include_credit = false
    include_refund = false
  }

  # 80% of the cap, measured against ACTUAL spend — "you've already burned this much".
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # 90% ACTUAL — the kill-switch trigger. Budgets refreshes spend data only a few times a day, so
  # any threshold fires up to ~12h late (~$3–4 at the ~$200/mo platform burn). 90% of $110 = $99,
  # so the automated teardown lands at roughly $103, still under the credit. A Lambda subscribed
  # to the SNS topic (future slice) acts on this one; the emails are the human trace.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
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
