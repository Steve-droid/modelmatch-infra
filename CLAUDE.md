# CLAUDE.md — modelmatch-infra

**Status: ACTIVE** (activated P1, 2026-06-10). Terraform for ModelMatch's AWS infrastructure.
Region **`ap-south-1`**, account **`832285994273`**.

> Part of the [ModelMatch portfolio build](../CLAUDE.md). Spec: `../docs/planning/architecture.md` §12,
> the locked DevOps backlog `../docs/planning/01-devops-backlog.md` (Epic **E10**), and
> `../docs/instructions/lesson-03` (Infrastructure) + `lesson-04` (FinOps).

## Two stacks, two lifecycles (the central design rule)

So the daily `destroy` can never nuke state, images, or the budget, Terraform is split into two root
stacks with **separate state**:

```
modelmatch-infra/
├── bootstrap/   # PERSISTENT — applied once, NEVER in the daily destroy
│   └── S3 state bucket + lock (P1) · AWS Budget+SNS (P2) · ECR repos imported (P5) · S3 ingestion bucket (P6)
├── platform/    # EPHEMERAL — `apply` at day start / `destroy` at day end
│   └── VPC+1×NAT (P3) · EKS+OIDC+nodes (P4) · IRSA roles A/B (P7)   ← the ONLY stack destroyed daily
└── modules/     # our OWN reusable modules (vpc, eks, ecr, iam-irsa, …) — populated from P3
```

- `bootstrap/` outputs (state-bucket ARN, ECR URLs, ingestion-bucket ARN) are read by `platform/` via
  `terraform_remote_state` — never duplicated.
- Each stack has its own `versions.tf` · `providers.tf` · `backend.tf` (+ `variables.tf` / `main.tf` /
  `outputs.tf` as needed). Same S3 bucket, **different state key** (`bootstrap/…` vs `platform/…`).

## State backend

- **S3 remote state**, bucket `modelmatch-tfstate-832285994273` (account-id suffix = globally unique).
  Versioned, AES256-encrypted, all public access blocked, `prevent_destroy` on the bucket.
- **Locking is S3-native** (`use_lockfile = true`, needs Terraform **≥ 1.10** — we run 1.15.5).
  **No DynamoDB lock table.** Backend blocks can't take variables, so bucket/key/region are literals
  kept in sync across the two `backend.tf` files.
- Chicken-and-egg resolved by **create-then-migrate**: `bootstrap/` was applied once with local state to
  create the bucket, then `terraform init -migrate-state` moved its own state into the bucket.

## Module rule — providers YES, third-party modules NO (Roey, hard rule)

**Providers are allowed and required** — use the official `hashicorp/aws` (and other official) providers
normally. The ban is on **third-party / community / registry Terraform _modules_**, because the course
grades whether *we* understand the AWS wiring (VPC, subnets, route tables, NAT, EKS, IAM/IRSA, ECR, S3
state) rather than hiding it behind someone else's module.

| Allowed | Not allowed |
|---|---|
| `source = "../modules/vpc"` (our own) | `source = "terraform-aws-modules/vpc/aws"` |
| direct `resource "aws_*"` blocks we write | `source = "terraform-aws-modules/eks/aws"` |
| `provider "aws" { … }` (official provider) | `source = "github.com/…"` / any registry module |

All reusable logic lives in **our own** `modules/` only. When in doubt: if `terraform init` would
download a module from the registry or a Git URL, it's banned.

## Tagging (FinOps + orphan hunt depend on it)

`default_tags` on the AWS provider in **every** stack stamps all taggable resources:

| key | value |
|---|---|
| `owner` | `steve` |
| `project` | `modelmatch` |
| `environment` | `dev` |
| `stack` | `bootstrap` \| `platform` (lifecycle discriminator for orphan-hunting) |

## Lifecycle & cost discipline

- `terraform apply` on **`platform/`** at day start → **`terraform destroy` on `platform/` at day end**.
  `bootstrap/` is persistent — **never** in the daily ritual.
- **Orphan ritual** after every platform destroy: verify **zero** stray ELBs, **unattached EBS volumes**,
  unattached EIPs, NAT GWs. (An EIP *attached* to the Jenkins box is fine.) Tags make orphans findable.
- **EKS:** latest in-support k8s version (stale = silent ~6× control-plane charge). **Exactly 1 NAT GW**
  in a single AZ — named egress SPOF for the HLD. **ECR lifecycle policy** (expire untagged, keep last N).
- **No hardcoded secrets, no static AWS keys.** In-cluster → Bedrock/S3 via **IRSA** (OIDC → role scoped
  to the 2 Nova ARNs + the S3 bucket → annotated on the backend SA). Auth on this machine = the default
  credential chain (`default` profile); no `profile` is hardcoded in HCL.

## Out of scope for this repo

- **Jenkins** is pre-provisioned on EC2 with a different lifecycle — **never in Terraform** (keeps
  `destroy` from taking out CI). ECR *is* here (managed AWS service, outside the cluster).
- **No managed database (no RDS).** The DB is **in-cluster** (Helm subchart + PVC — see
  [`modelmatch-gitops`](../modelmatch-gitops)).

  > **Postgres persistence (forward note for gitops P13/P14, Roey 2026-06-10):** the PVC must be backed
  > by the **AWS EBS CSI driver** (EBS-backed StorageClass) — never hostPath / container disk. The volume
  > must survive pod restarts and Helm redeploys. If survival across **cluster rebuilds** is required,
  > use `reclaimPolicy: Retain` + a documented re-bind/restore procedure (or EBS snapshots). A retained
  > EBS volume is a **cost orphan** if forgotten — document how it's found, reattached, or deleted in the
  > orphan ritual. (Driver itself installs via EKS addon / gitops; persistence config lives in the chart.)

## Branching

`feature/<story-id>-<desc>` → PR (self-review) → `main` (protected). The scaffold/shell commit was the
one direct-to-`main` exception; everything since is on feature branches. Confirm with Steve before any
commit/push. Local-first (no remote yet).
