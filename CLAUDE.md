# CLAUDE.md — modelmatch-infra

**Status: ACTIVE** (activated P1, 2026-06-10). Terraform for ModelMatch's AWS infrastructure.
Region **`ap-south-1`**, account **`957261948820`**.

> Part of the [ModelMatch portfolio build](../CLAUDE.md). Spec: `../docs/planning/architecture.md` §12,
> the locked DevOps backlog `../docs/planning/01-devops-backlog.md` (Epic **E10**), and
> `../docs/instructions/lesson-03` (Infrastructure) + `lesson-04` (FinOps).

## Three stacks, three lifecycles (the central design rule)

So the daily `destroy` can never nuke state, images, the budget, **or the CI controller**, Terraform is
split into three root stacks with **separate state**:

```
modelmatch-infra/
├── bootstrap/   # PERSISTENT — applied once, NEVER in the daily destroy
│   └── S3 state bucket + lock (P1) · AWS Budget+SNS (P2) · ECR repos imported (P5) · S3 ingestion bucket (P6)
├── platform/    # EPHEMERAL — `apply` at day start / `destroy` at day end
│   └── VPC+1×NAT (P3) · EKS+OIDC+nodes (P4) · IRSA roles A/B (P7)   ← the ONLY stack destroyed daily
├── jenkins/     # PERSISTENT — CI controller; survives every platform destroy (P16, E11; Roey 2026-06-15)
│   └── Jenkins EC2 + EIP + SG + IAM instance profile + persistent EBS (/var/lib/jenkins) + optional backup bucket
└── modules/     # our OWN reusable modules (vpc, eks, ecr, iam-irsa, …) — populated from P3
```

- `bootstrap/` outputs (state-bucket ARN, ECR URLs, ingestion-bucket ARN) are read by `platform/` via
  `terraform_remote_state` — never duplicated.
- Each stack has its own `versions.tf` · `providers.tf` · `backend.tf` (+ `variables.tf` / `main.tf` /
  `outputs.tf` as needed). Same S3 bucket, **different state key** (`bootstrap/…` vs `platform/…` vs
  `jenkins/…`).
- **`jenkins/` is persistent** (like `bootstrap/`) but kept a **separate root** because it isn't
  foundational *shared* infra — it has its own lifecycle + operational surface (EC2, plugins, jobs, an
  attached disk). Built/proven in **P16**; destroyed only intentionally, never in the daily ritual.
  `JENKINS_HOME` lives on the persistent EBS volume; S3 = encrypted backup/DR only. See
  `../docs/planning/mentor-notes-2026-06-15.md` §1–§3.

## State backend

- **S3 remote state**, bucket `modelmatch-tfstate-957261948820` (account-id suffix = globally unique).
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

## Variables & values — defaultless `variables.tf` + explicit `-var-file` (Roey, hard rule)

**`variables.tf` declares inputs only, with NO defaults.** Concrete **non-secret** values live in an
explicit `.tfvars` file (`bootstrap/dev.tfvars`, `platform/dev.tfvars`), passed on **every** command
with **`-var-file=dev.tfvars`**. **Do not rely on auto-loaded `terraform.tfvars` / `*.auto.tfvars`** —
the var-file is always named explicitly so nothing is implicit.

- **Why:** predictability — a forgotten `default` (or a silently auto-loaded tfvars) can feed a
  `terraform apply` and create resources you didn't mean to. Every value is explicit and in one place.
- **Modules** (`modules/*/variables.tf`): defaultless variables = the module interface (values come
  from the calling stack, never module defaults).
- **Stack roots** (`bootstrap/`, `platform/`, and `jenkins/` once it lands at P16): defaultless
  `variables.tf` + a committed non-secret `dev.tfvars`; `module`/`provider` blocks read `var.*` (e.g.
  region is `var.aws_region`).
- **Secrets never go in tfvars** — they reach the cluster via Secrets Manager (ESO + IRSA). The
  committed `dev.tfvars` is non-secret on purpose; `.gitignore` ignores `*.tfvars` but **un-ignores
  `bootstrap/dev.tfvars` + `platform/dev.tfvars`** specifically (`jenkins/dev.tfvars` joins the un-ignore
  list when the `jenkins/` root is created at P16).
- Always run `plan`/`apply` with the var-file explicit:
  `terraform -chdir=bootstrap <cmd> -var-file=dev.tfvars`,
  `terraform -chdir=platform <cmd> -var-file=dev.tfvars`, and
  `terraform -chdir=jenkins <cmd> -var-file=dev.tfvars` (once `jenkins/` exists).

> **All three stack roots follow this rule** (`jenkins/` adopts it when it lands at P16). `bootstrap/`
> originally carried `default`s (it predated the rule); it was migrated to defaultless `variables.tf` +
> `bootstrap/dev.tfvars` — the tfvars values are byte-identical to the old defaults, so the migration is
> a no-op to the plan.

## Tagging (FinOps + orphan hunt depend on it)

`default_tags` on the AWS provider in **every** stack stamps all taggable resources:

| key | value |
|---|---|
| `owner` | `steve` |
| `project` | `modelmatch` |
| `environment` | `dev` |
| `stack` | `bootstrap` \| `platform` \| `jenkins` (lifecycle discriminator for orphan-hunting) |

## Lifecycle & cost discipline

- `terraform apply` on **`platform/`** at day start → **`terraform destroy` on `platform/` at day end**.
  `bootstrap/` **and `jenkins/`** are persistent — **never** in the daily ritual (`jenkins/` is destroyed
  only intentionally).
- **Orphan ritual** after every platform destroy: verify **zero** stray ELBs, **unattached EBS volumes**,
  unattached EIPs, NAT GWs. (An EIP *attached* to the Jenkins box is fine.) Tags make orphans findable.
- **EKS:** latest in-support k8s version (stale = silent ~6× control-plane charge). **Exactly 1 NAT GW**
  in a single AZ — named egress SPOF for the HLD. **ECR lifecycle policy** (expire untagged, keep last N).
- **No hardcoded secrets, no static AWS keys.** In-cluster → Bedrock/S3 via **IRSA** (OIDC → role scoped
  to the 2 Nova ARNs + the S3 bucket → annotated on the backend SA). Auth on this machine = the default
  credential chain (`default` profile); no `profile` is hardcoded in HCL.

## Repo boundaries (what's here vs not)

- **Jenkins** — **revised 2026-06-15: now IN scope for this repo**, managed by the persistent **`jenkins/`**
  root above (P16; it was previously planned as pre-provisioned / out-of-Terraform). Kept **out of the
  daily-destroyed `platform/` stack** so `destroy` can't take out CI, and still **outside the EKS cluster**
  (standalone EC2). ECR *is* here too (managed AWS service, outside the cluster).
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
