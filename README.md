# modelmatch-infra

> **SHELL repo (inactive).** Activates when the infrastructure stories begin (after the app core
> works). This README describes the intended shape; run instructions land when the repo goes ACTIVE.
> Part of the [ModelMatch portfolio build](../CLAUDE.md); spec in
> [`../docs/planning/architecture.md`](../docs/planning/architecture.md) §12 and `../docs/instructions/lesson-03..04`.

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

## Repository Structure (planned)

```
modelmatch-infra/
├── modules/        # own Terraform modules (vpc, eks, ecr, iam-irsa, s3)
├── envs/           # root configs / backend + variables per environment
├── .gitignore
├── README.md
└── CLAUDE.md
```

## Conventions

- No hardcoded secrets; S3 remote state; least-privilege IRSA; tag every resource (owner/project/env).
- Jenkins is **not** in Terraform (it is pre-provisioned, different lifecycle — keeps `destroy` safe).
- `terraform apply` at day start, **`terraform destroy` at day end**, then the orphan check (no stray
  ELB / EBS / EIP / NAT). An AWS Budget is wired to an alert.
- Branching: `feature/<story-id>-<desc>` → PR → `main` (protected).

## Contact

Steve Levit — stevelevit230@gmail.com
