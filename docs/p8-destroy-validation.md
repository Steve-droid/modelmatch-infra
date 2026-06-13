# P8 — Platform-stack destroy validation (evidence)

**Date:** 2026-06-13 · **Epic:** E10 (infra foundation) · **Stack:** `platform/` only ·
**Account:** `832285994273` · **Region:** `ap-south-1`

> **Recorded run:** post the bootstrap defaultless-variables migration (`main` `54c2569`, tag
> `v0.8.0`). P8 was re-run on the migrated tree so the recorded proof reflects the final code. An
> earlier pre-migration dry-run passed identically; the bootstrap migration is a proven no-op
> (`terraform -chdir=bootstrap plan -var-file=dev.tfvars` → **No changes**), so the platform teardown
> behaviour is unchanged.

## Why this exists

`platform/` is the **ephemeral** stack — `apply` at day start, `destroy` at day end, so EKS + the NAT
gateway stop billing overnight. P8 is the **recorded proof** that this daily teardown:

1. tears down **every** platform resource (no orphans left billing), and
2. **cannot reach** the persistent `bootstrap/` stack (state bucket, AWS Budget, ECR `:1.0.0` images,
   ingestion bucket) — different state, `prevent_destroy` on the bucket.

Proving it **now**, before stateful workloads (in-cluster Postgres, secrets) land in E12, means a
botched destroy can never take out data later. This is the last slice of E10.

## Sequence run (each mutation gated on explicit approval)

`fresh apply → snapshot → destroy → orphan check → re-apply`, all on `platform/` only. `bootstrap/`
was never destroyed (only a read-only `plan` to confirm the migration is a no-op).

| Step | Command | Result |
|---|---|---|
| Fresh apply | `terraform -chdir=platform apply -var-file=dev.tfvars` | **35 added, 0 changed, 0 destroyed** |
| Destroy | `terraform -chdir=platform destroy -var-file=dev.tfvars` | **35 destroyed**; `state list` = 0 |
| Re-apply | `terraform -chdir=platform apply -var-file=dev.tfvars` | **35 added**; cluster `ACTIVE` |

## Pre-destroy live snapshot (the set that had to vanish)

| Resource | ID(s) |
|---|---|
| VPC | `vpc-044daf9dbed313970` |
| Subnets (4) | `subnet-0f3c0d5cc54667f96`, `subnet-04cc4c8768db8dd3d`, `subnet-06ae89032b84b31a3`, `subnet-0787949d7a313489a` |
| NAT GW | `nat-007b41e2d7bbf872a` |
| NAT EIP | `eipalloc-0763c291463ee1425` |
| IGW | `igw-0974925384e391ff1` |
| Route tables (3) | `rtb-07433ebd8f67850ba`, `rtb-0855a8407c7a1a928`, `rtb-04660e7ae5282afc3` |
| EKS cluster | `modelmatch` (v1.36) |
| OIDC provider | `…/id/7D285D90461FFEB8CFE9BE0AFA910625` |
| IAM roles (5) | `modelmatch-backend-irsa`, `modelmatch-eso-irsa`, `modelmatch-eks-cluster-role`, `modelmatch-eks-node-role`, `modelmatch-ebs-csi-irsa` |

## Orphan check after destroy (read-only; all clean)

Tag filter: `Name=tag:stack,Values=platform`.

| Check | Result |
|---|---|
| Platform-tagged VPC / subnets / NAT (non-deleted) / IGW / route tables | **all empty** |
| EKS clusters (`aws eks list-clusters`) | **none** |
| 5 platform IAM roles (`aws iam get-role`) | **NoSuchEntity** (all gone) |
| OIDC provider | **gone** (`list-open-id-connect-providers` empty) |
| Unattached EIPs (`AssociationId == null`) | **none** |
| Unattached EBS volumes (`status=available`) | **none** |
| Load balancers (ELBv2 + classic) | **none** |

**EIP note (orphan ritual):** the only EIPs in the region — `15.206.12.120` (Jenkins) and
`13.126.189.239` (app smoke box) — are both **attached** to their EC2 instances. An EIP *attached* to
the Jenkins box is **not** an orphan; the EC2 smoke env is outside Terraform and is the graded CI.
Only an *unattached* EIP would bill as waste.

## Bootstrap survived untouched (proof)

| Bootstrap resource | Baseline | After destroy |
|---|---|---|
| ECR `modelmatch-backend:1.0.0` | `sha256:a3b119f7…aa93e` | **identical** |
| ECR `modelmatch-frontend:1.0.0` | `sha256:276e6f85…f506e` | **identical** |
| ECR `modelmatch-agent:1.0.0` | `sha256:a0e966fd…fe7e1` | **identical** |
| State bucket `modelmatch-tfstate-832285994273` | PRESENT | **PRESENT** |
| Ingestion bucket `modelmatch-ingestion-sources` | PRESENT | **PRESENT** |
| AWS Budget `modelmatch-monthly-cost` | PRESENT | **PRESENT** |

ECR `:1.0.0` digests match **bit-for-bit** across the destroy — the persistent stack is provably
immune to the daily ritual.

## New ephemeral IDs after re-apply (all changed — confirms clean recreate)

| Resource | Pre-destroy | After re-apply |
|---|---|---|
| VPC | `vpc-044daf9dbed313970` | `vpc-0a7c12dd9420d3161` |
| NAT GW | `nat-007b41e2d7bbf872a` | `nat-094573e8cd05e69b6` |
| NAT EIP | `eipalloc-0763c291463ee1425` | `eipalloc-02205a1f4ecb575e3` |
| OIDC issuer | `7D285D90…` | `60744325F60408A76CDA3CC93F3BC6DC` |

> **OIDC issuer regenerates on every cluster recreate** — every cluster build this session produced a
> distinct issuer (P7 `5B2F8D…`, then `C8359906…`, `236D0F5A…`, `7D285D90…`, `60744325…`). Any consumer
> must reference `module.eks.oidc_provider_arn` **dynamically**, never hardcode it. (Already the case in
> `platform/irsa.tf` — the IRSA roles came back bound to the new issuer with no code change.)

## Verdict

P8 **PASS** — platform destroys clean (zero orphans across NAT/EIP/subnet/RT/SG/VPC/EKS/OIDC + the 5
IAM roles), bootstrap (ECR `:1.0.0` + state + budget + ingestion bucket) survived untouched, and
re-apply restored a working `ACTIVE` cluster. The daily cost ritual is validated, and the bootstrap
defaultless-variables migration changed none of it. Platform left **UP** after re-apply — destroy at
day end as usual.
