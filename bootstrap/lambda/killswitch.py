"""Budget kill switch: AWS Budgets alert (via SNS) -> start the platform-teardown CodeBuild project.

Runs in us-east-1 (SNS lambda subscriptions must be in the topic's region; Budgets can only notify a
us-east-1 topic) and starts the CodeBuild project cross-region in ap-south-1. The whole trigger is
~40 lines on purpose: no retries, no state — CodeBuild's concurrent_build_limit=1 de-duplicates.

Fires when EITHER
  (a) the SNS text is the ACTUAL alert at >= TRIGGER_PERCENT for our budget (the 80% / FORECASTED
      messages hit the same topic and are ignored), or
  (b) the Budgets API says month-to-date actual spend / limit >= TRIGGER_PERCENT — ground truth that
      does not depend on the exact wording of the alert text.
DRY_RUN (env, "1"/"0") is passed straight to the build: "1" = plan-only teardown, "0" = the real one.
"""

import logging
import os
import re

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

PROJECT = os.environ["CODEBUILD_PROJECT"]
PROJECT_REGION = os.environ["CODEBUILD_REGION"]
BUDGET_NAME = os.environ["BUDGET_NAME"]
BUDGET_LIMIT_USD = float(os.environ["BUDGET_LIMIT_USD"])
TRIGGER_PERCENT = float(os.environ["TRIGGER_PERCENT"])
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
DRY_RUN = os.environ.get("DRY_RUN", "1")  # missing -> fail-safe

codebuild = boto3.client("codebuild", region_name=PROJECT_REGION)
budgets = boto3.client("budgets", region_name="us-east-1")


def _field(text: str, name: str) -> str:
    """Value of a 'Name: value' line in the Budgets alert body ('' when absent)."""
    m = re.search(rf"^{re.escape(name)}:\s*(.+)$", text, re.MULTILINE)
    return m.group(1).strip() if m else ""


def message_matches(text: str) -> tuple[bool, str]:
    """(a) text filter. Budgets renders the threshold in dollars ('Alert Threshold: > $99.00') even for
    percentage thresholds, so accept either a percent or a dollar amount >= the trigger."""
    if _field(text, "Budget Name") != BUDGET_NAME:
        return False, "budget name mismatch"
    if _field(text, "Alert Type").upper() != "ACTUAL":
        return False, "alert type is not ACTUAL"
    threshold = _field(text, "Alert Threshold")
    numbers = re.findall(r"\d+(?:\.\d+)?", threshold.replace(",", ""))
    if not numbers:
        return False, f"no number in threshold {threshold!r}"
    value = float(numbers[-1])
    if "%" in threshold:
        ok = value >= TRIGGER_PERCENT
    else:
        ok = value >= BUDGET_LIMIT_USD * TRIGGER_PERCENT / 100 - 0.01
    return ok, f"threshold {threshold!r}"


def budget_ratio() -> float | None:
    """(b) ground truth: month-to-date actual spend / limit, per the budget's own cost_types (gross)."""
    try:
        b = budgets.describe_budget(AccountId=ACCOUNT_ID, BudgetName=BUDGET_NAME)["Budget"]
        actual = float(b["CalculatedSpend"]["ActualSpend"]["Amount"])
        limit = float(b["BudgetLimit"]["Amount"])
        return actual / limit if limit else None
    except Exception as exc:  # the text filter still works without the API
        log.warning("describe_budget failed: %s", exc)
        return None


def handler(event, _context):
    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        text = sns.get("Message") or ""
        log.info("received message_id=%s subject=%r", sns.get("MessageId"), sns.get("Subject"))
        matched, why = message_matches(text)
        ratio = budget_ratio()
        api_fires = ratio is not None and ratio >= TRIGGER_PERCENT / 100
        log.info("filter: text_matched=%s (%s) budget_ratio=%s api_fires=%s dry_run=%s",
                 matched, why, None if ratio is None else round(ratio, 4), api_fires, DRY_RUN)
        if not (matched or api_fires):
            log.info("ignored")
            continue
        build = codebuild.start_build(
            projectName=PROJECT,
            environmentVariablesOverride=[{"name": "DRY_RUN", "value": DRY_RUN, "type": "PLAINTEXT"}],
        )["build"]
        log.info("KILL SWITCH: started build %s with DRY_RUN=%s", build["id"], DRY_RUN)
    return {"ok": True}
