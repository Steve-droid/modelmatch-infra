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
