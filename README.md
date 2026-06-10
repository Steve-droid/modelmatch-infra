# modelmatch-infra

> **ACTIVE** (since P1). Terraform foundation for ModelMatch's AWS infrastructure.
> Part of the [ModelMatch portfolio build](../CLAUDE.md); spec in
> [`../docs/planning/architecture.md`](../docs/planning/architecture.md) §12 and `../docs/instructions/lesson-03..04`.
> Operator guidance: [`CLAUDE.md`](CLAUDE.md).

## Overview

Terraform (own modules — **no third-party modules**) for ModelMatch's AWS infrastructure. Built
cost-aware from the start: lifecycle discipline (`apply` at day start / `destroy` at day end) and the
orphan-resource ritual check are first-class.

What it will provision (region **`ap-south-1`**):

- **EKS** — latest in-support Kubernetes version (a stale version is a silent ×6 cluster charge).
- **VPC** — private subnets + **exactly one NAT Gateway** in a single AZ (the SPOF tradeoff is named in
  the HLD); **single ingress load balancer** (FE + BE behind one LB).
- **ECR** — with a lifecycle policy (expire untagged, keep last N tagged).
- **IAM + IRSA** — OIDC provider → role scoped to the Bedrock Nova model ARNs + the S3 bucket →
  annotated onto the backend ServiceAccount (no static keys in the cluster).
- **S3** — Terraform remote state + ingestion source-doc blobs.

> **No managed database.** Per the build module the **database is in-cluster** (a Helm subchart on a
> PVC — see [`modelmatch-gitops`](../modelmatch-gitops)). This repo provisions **no RDS**.

## Technology Stack

| Category           | Technologies   |
| ------------------ | -------------- |
| **Infrastructure** | AWS (EKS, VPC, NAT, ECR, IAM/IRSA, S3) |
| **IaC**            | Terraform — own modules; S3 remote state backend |
| **Region**         | `ap-south-1` (Mumbai) |

## Repository Structure

Two root stacks with separate state and separate lifecycles (so the daily `destroy` can't nuke state,
images, or the budget), plus a shared dir for our own modules:

```
modelmatch-infra/
├── bootstrap/      # PERSISTENT — applied once, never in the daily destroy
│   │               #   S3 state bucket + lock (P1) · Budget+SNS (P2) · ECR (P5) · ingestion bucket (P6)
│   ├── versions.tf · providers.tf · backend.tf · variables.tf · main.tf · outputs.tf
├── platform/       # EPHEMERAL — apply at day start / destroy at day end
│   │               #   VPC+1×NAT (P3) · EKS+OIDC (P4) · IRSA (P7)  ← the only stack destroyed daily
│   ├── versions.tf · providers.tf · backend.tf · variables.tf
├── modules/        # our OWN modules only (vpc, eks, ecr, iam-irsa, …) — populated from P3
├── .gitignore  ·  README.md  ·  CLAUDE.md
```

Both stacks use the same S3 state bucket with different keys; `platform/` reads `bootstrap/` outputs via
`terraform_remote_state`.

## Usage

```bash
# bootstrap (persistent) — applied once; rarely re-run
cd bootstrap && terraform init && terraform apply

# platform (ephemeral) — the daily cycle
cd platform  && terraform init && terraform apply     # day start
cd platform  && terraform destroy                     # day end, then run the orphan check
```

Auth uses the default AWS credential chain (the `default` profile / env vars) — no `profile` is
hardcoded in HCL, and no static keys are committed.

## Cost alerting (P2)

The financial ground-truth backstop, created **early** (before the first EKS apply) and in the
**persistent `bootstrap/` stack** so it survives the daily `platform/` destroy.

```
  aws_budgets_budget (modelmatch-monthly-cost, $25/mo, COST)
        │   notify @ 80% ACTUAL  +  100% FORECASTED   (both % of the cap)
        ├──────────────────────────────────────────────┐
        ▼                                               ▼
  subscriber_email_addresses              subscriber_sns_topic_arns
  → stevelevit230@gmail.com               → aws_sns_topic modelmatch-budget-alerts ⚠ us-east-1
    (RELIABLE channel)                       (+ topic policy: allow budgets.amazonaws.com
                                              to SNS:Publish, scoped to our account)
                                             → email subscription (pattern + future fan-out)
```

**Two delivery channels, on purpose:**

- **Budget-native email** (`subscriber_email_addresses`) is the **reliable** channel. These mails come
  straight from AWS Budgets and carry **no unsubscribe link**, so Gmail's link-prefetch (security
  scanning of incoming mail) can't silently deactivate them.
- **SNS topic** (`subscriber_sns_topic_arns`) is kept for the topic/subscription pattern and future
  programmatic fan-out (Slack/Lambda) — **not** relied on for email. SNS *raw email* subscriptions are
  fragile with Gmail: the unsubscribe link in every SNS notification gets prefetched on receipt and
  auto-deactivates the subscription. (Known failure mode; documented here so we don't relearn it.)

**Why us-east-1:** AWS Budgets is a *global* service whose backend runs in us-east-1, and a budget can
only notify an SNS topic that also lives in us-east-1. The budget itself is managed through the default
`ap-south-1` provider (Budgets is global); only the topic needs the `aws.us_east_1` alias.

**Scope:** covers AWS-side spend (EKS control plane + NAT + EBS + data transfer). Anthropic app-API
spend is tracked separately on the Anthropic console — *not* here. Per lesson-04, cost stays out of
Prometheus; this Budget + Cost Explorer is the financial signal, token metrics are the operational one.

**Verifying the alert path (the budget-native channel is the one that matters):**

AWS Budgets has no "send test notification" button — a real email only fires when AWS evaluates
month-to-date spend against the threshold (a few times a day). To prove it end-to-end without waiting
for a real overrun, temporarily lower the limit below current MTD spend so the threshold trips, then
restore it (keep the real limit out of the change by using a `-var` override):

```bash
aws ce get-cost-and-usage --region us-east-1 \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --query 'ResultsByTime[0].Total.UnblendedCost'          # current month-to-date spend

terraform apply -var="budget_limit_amount=1"   # 80% = $0.80 < MTD spend → trips on next eval
#   … wait for the budget email (from budgets@costalerts.amazonaws.com), then:
terraform apply                                 # restore to the committed $25 limit
```

> **Verification performed 2026-06-10:** limit temporarily dropped to `$1` via `-var` against a
> month-to-date spend of `$1.55`. Both notifications fired as real budget-native emails from
> `budgets@costalerts.amazonaws.com`, delivered to the subscriber's **inbox** (not spam):
> **ACTUAL** `$1.55 > $0.80` (80% of $1) and **FORECASTED** `$4.82 > $1.00` (100% of $1).
> Limit restored to `$25`; final `terraform plan` = no changes. The SNS email subscription was
> separately confirmed active (`PendingConfirmation: false`).

## Conventions

- **Providers yes, third-party modules no** (hard rule): official providers like `hashicorp/aws` are
  required, but **every module must be ours** (`source = "../modules/…"`). No registry/Git modules —
  see [`CLAUDE.md`](CLAUDE.md).
- **S3 remote state** with S3-native locking (`use_lockfile`, Terraform ≥ 1.10 — no DynamoDB).
- No hardcoded secrets / no static keys; least-privilege IRSA; **tag every resource** via `default_tags`
  (`owner` / `project` / `environment` / `stack`).
- Jenkins is **not** in Terraform (pre-provisioned, different lifecycle — keeps `destroy` safe).
- `terraform apply` (platform) at day start, **`terraform destroy` (platform) at day end**, then the
  orphan check (no stray ELB / unattached EBS / unattached EIP / NAT). An AWS Budget is wired to an alert (P2).
- Branching: `feature/<story-id>-<desc>` → PR → `main` (protected).

## Contact

Steve Levit — stevelevit230@gmail.com
