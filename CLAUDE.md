# CLAUDE.md — modelmatch-infra

**Status: SHELL (inactive).** Placeholder; activates when the infrastructure stories begin (after the
app core works).

> **When work starts here:** flip status to **ACTIVE** and fill in real guidance (module layout, state
> backend, resources, IAM/IRSA). Until then this is a stub.

## What it will be

**Terraform (own modules — no third-party)** for ModelMatch's cloud infra: **EKS** (latest in-support
version), **VPC** with private subnets + **exactly one NAT** (single AZ — name the SPOF tradeoff in the
HLD), **ECR**, **IAM + IRSA** (OIDC → role scoped to Bedrock Nova model ARNs + the S3 bucket → annotated
on the backend ServiceAccount), **S3** (Terraform state + ingestion blobs). Region **`ap-south-1`**.

> **No managed database here.** Per the build module the **DB is in-cluster** (Helm subchart + PVC, see
> `modelmatch-gitops`) — infra provisions **no RDS**.

**Rules (when active):** no hardcoded secrets; S3 remote state; least-privilege IRSA; latest EKS
version; single NAT + single ingress LB; ECR lifecycle policy; tag every resource;
`apply` at day start / **`destroy` at day end** + orphan check (no stray ELB/EBS/EIP/NAT).

See the umbrella `../CLAUDE.md` and `../docs/planning/architecture.md` §12 + `../instructions/lesson-03..04`.
