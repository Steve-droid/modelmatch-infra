# P16 — Jenkins CI controller (the persistent `jenkins/` Terraform root)

> **Epic E11, slice P16 (Roey 2026-06-15 locked plan).** Stands up the **graded CI controller** as a
> third, persistent Terraform root — `modelmatch-infra/jenkins/` — and wires its identities, secrets,
> and webhooks, then **proves** them. It does **not** build the FE/BE/agent pipelines (P17/P18/P19).
> Region `ap-south-1`, account `832285994273`.

## Where it sits — three roots, three lifecycles

| Root | Lifecycle | State key |
|---|---|---|
| `bootstrap/` | persistent — never daily-destroyed (state, budget, **ECR**, ingestion bucket) | `bootstrap/…` |
| `platform/` | **ephemeral** — apply at day start / destroy at day end (VPC, EKS, IRSA) | `platform/…` |
| **`jenkins/`** | **persistent** — applied once, **survives every `platform` destroy**, destroyed only intentionally | **`jenkins/…`** |

`jenkins/` lives in the **default VPC** (not `platform/`'s VPC), so the daily `platform` destroy cannot
reach it. It is **not** folded into `bootstrap/` because it is not foundational shared infra — it has its
own operational surface (an EC2 box, an attached disk, plugins, jobs).

## What the stack builds (`modules/jenkins-controller`)

- **EC2 controller** (`t3a.medium`) bootstrapped by `user_data` (clean Ubuntu base → installs Docker +
  AWS CLI v2 + Jenkins native + jq/git, mounts the EBS home, pre-installs plugins). IMDSv2 required.
- **Persistent encrypted EBS** at `/var/lib/jenkins` (`prevent_destroy`) — the **live source of truth**
  for Jenkins state; survives instance replacement. **S3 is backup/DR only**, never a live sync; the
  controller `master.key`/secrets are never backed up decrypted.
- **Security group** — SSH (22) + UI (8080) from the admin `/32`; **8080 also open to GitHub's published
  hook ranges** for webhook delivery.
- **IAM instance profile** — the box's **only** AWS identity (no static keys): `bedrock:InvokeModel` on
  the 2 Nova ARNs (mirrors platform IRSA role A) + **ECR push** to the 3 repos + `secretsmanager` read on
  `modelmatch-jenkins-*` (+ account-wide `ListSecrets` for the plugin).
- **Static EIP** — a stable UI + webhook target across stop/start.

### Two identities, deliberately separate

```
Jenkins EC2
 ├─ instance profile (AWS only)  → ECR push + bedrock:InvokeModel (e2e-live)   [NO static keys]
 └─ Secrets Manager modelmatch-jenkins-*  (via the Credentials Provider plugin)
       PERSISTENT (keep — P17/P18 reuse):
       ├─ modelmatch-jenkins-gitops-deploy-key   → WRITE to modelmatch-gitops (a Git write, NOT an AWS API)
       ├─ modelmatch-jenkins-frontend-read-key   → READ  modelmatch-frontend (PRIVATE) for checkout
       ├─ modelmatch-jenkins-backend-read-key    → READ  modelmatch-backend  (PRIVATE) for checkout
       THROWAWAY (delete after the proof is green):
       └─ modelmatch-jenkins-p16-proof-webhook-hmac → proof-only HMAC (NOT the future FE/BE HMACs)
```
> **Naming note:** the secrets use a **flat, slash-free `modelmatch-jenkins-*` prefix** (not the planned
> literal `modelmatch/jenkins/*`). The AWS Secrets Manager Credentials Provider plugin uses the secret
> name as the Jenkins **credential ID**, which must match `[a-zA-Z0-9_.-]+` — `/` is disallowed. The IAM
> least-privilege scope (`secretsmanager:GetSecretValue` on `modelmatch-jenkins-*`) and the dedicated
> namespace (distinct from the app's `modelmatch/app`) are unchanged.

The **AWS role cannot write GitHub; the deploy keys cannot call AWS.** A compromise of one is not the
other. (FE/BE are **private** → read keys are needed; gitops is public but a **push** still needs the
write key; infra needs **no** key — Jenkins CI never checks it out. Demo BYOK + public-registry creds are
deferred to P18/P19.)

## Decisions baked in (P16 forks — Steve 2026-06-15)

1. **Build fresh, not import.** `user_data` only runs at first boot, so an imported, already-booted box
   would never execute the bootstrap — import cannot deliver the locked "user_data bootstraps" plan.
   We build a fresh box and keep the old smoke box as a backup until the new proof is green.
2. **Clean Ubuntu 24.04 base** (`ami-006f82a1d5a27da54`), not the restore AMI. The restore AMI
   (`ami-03cfe8d7787b8eb3c`) runs a docker-compose Jenkins that fights the native `/var/lib/jenkins` plan;
   a clean base + full `user_data` is reproducible IaC. The restore AMI is preserved as a backup (below).
3. **Webhook = plain HTTP `:8080` + HMAC**, SCM polling as the documented fallback. HMAC protects
   authenticity; the payload is push metadata, not secrets. (The app proves cert-manager TLS at P15 — we
   don't prove TLS twice on a single box.)
4. **EIP:** the new box gets a **fresh TF-managed EIP** during build (the old box keeps `15.206.12.120`
   untouched until proof-green). At cutover, either reassociate `15.206.12.120` or keep the new EIP and
   update the runbook/webhook references.

## Procedure

> Every cloud mutation below needs Steve's explicit OK. `platform/` stays **DOWN** for P16.

### 0. Backup the old smoke box first (recovery point)
**Precondition — the box must be STOPPED** so the AMI is filesystem-consistent (a no-reboot AMI of a
*running* box can be inconsistent; of a *stopped* box it is fine). Verify, then image:
```bash
aws ec2 describe-instances --region ap-south-1 --instance-ids i-0f701eeb64a1d2bbd \
  --query 'Reservations[].Instances[].State.Name' --output text   # must print: stopped

aws ec2 create-image --region ap-south-1 --no-reboot \
  --instance-id i-0f701eeb64a1d2bbd \
  --name "jenkins-smoke-backup-2026-06-15" \
  --description "P16 pre-cutover backup of the smoke Jenkins controller" \
  --tag-specifications 'ResourceType=image,Tags=[{Key=owner,Value=steve},{Key=project,Value=modelmatch},{Key=environment,Value=dev},{Key=stack,Value=jenkins},{Key=Name,Value=jenkins-smoke-backup}]'
```
**Do not terminate the old box** — leave it stopped as a fallback until the new proof is green.

> **As run 2026-06-15:** old box `i-0f701eeb64a1d2bbd` (stopped) → AMI **`ami-09b7b3c1bf00385f4`**
> (`jenkins-smoke-backup-2026-06-15`) backed by snapshot **`snap-0cbd070bf971a3536`** (both tagged
> `stack=jenkins`). This is the recovery point if the build-fresh cutover needs to roll back.

### 1. Apply the stack
```bash
terraform -chdir=jenkins init                       # first time: configures the S3 backend (key jenkins/)
terraform -chdir=jenkins plan  -var-file=dev.tfvars # expect: SG, role, instance profile, EBS, instance, attach, EIP, assoc
terraform -chdir=jenkins apply -var-file=dev.tfvars
terraform -chdir=jenkins output                     # note jenkins_url + jenkins_webhook_url + jenkins_public_ip
```

> **As run 2026-06-15 (9 added / 0 changed / 0 destroyed):** first instance **`i-07ab6bc135b1a2a2c`** ·
> EIP **`3.6.214.36`** (`eipalloc-05358bde3db40a298`) · role `modelmatch-jenkins-role` · SG
> `sg-00bd16bd599fa9f2d` · JENKINS_HOME volume **`vol-051e69f928d0ae33f`** (encrypted, prevent_destroy).
>
> **First boot FAILED** — Jenkins had rotated its `debian-stable` apt signing key; the old
> `jenkins.io-2023.key` no longer matched the repo Release (now signed by `7198F4B714ABFC68`), so apt
> rejected the repo and `set -euo pipefail` aborted `user_data` before installing Jenkins (diagnosed via
> `aws ec2 get-console-output`). **Fixed in `user_data.sh.tftpl`:** trust the repo with the published
> **`jenkins.io-2026.key`** (carries `7198F4B714ABFC68`; keyserver = verified fallback only), **Java 21**,
> and a hardened (non-fatal, deterministic) EBS-fallback. Re-ran the fixed bootstrap with a **gated
> `terraform apply -replace=module.jenkins.aws_instance.this`** (3 add / 0 change / 3 destroy — EIP +
> EBS persisted) → **final instance `i-0b8513065f06a4324`**. Clean console log: published 2026 key
> verified (no keyserver fallback), Java 21, JENKINS_HOME on `/dev/nvme1n1` (ext4, by-UUID `nofail`
> fstab), Jenkins 2.555.3 active, `aws sts` shows the instance role. UI `http://3.6.214.36:8080` ·
> webhook `http://3.6.214.36:8080/github-webhook/`. EIP cutover decision deferred to step 5.

### 2. One-time Jenkins setup (UI)
- Browse `http://<eip>:8080`; unlock with the initial admin password
  (`sudo cat /var/lib/jenkins/secrets/initialAdminPassword` over SSH with `develeap-key`).
- **Skip "install suggested plugins"** (user_data pre-installed ours); create the admin user.
- Confirm the **AWS Secrets Manager Credentials Provider** + **GitHub** plugins are present (Manage
  Jenkins → Plugins). If `user_data`'s best-effort pre-install missed any, install via the UI.
- Configure the provider (Manage Jenkins → Credentials Provider): region `ap-south-1`, prefix filter
  `modelmatch-jenkins-`. The instance role already grants read.

### 3. Bootstrap pipeline credentials + deploy keys + webhook (GATED)
```bash
./docs/p16/bootstrap-secrets.sh "$(terraform -chdir=jenkins output -raw jenkins_webhook_url)"
```
Creates the **3 persistent** SSH-key secrets + their 3 GitHub deploy keys (FE/BE read, gitops write),
then the **1 throwaway** proof-only HMAC (`modelmatch-jenkins-p16-proof-webhook-hmac`) + the public
`p16-proof` repo & its webhook (file://, never argv). Persistent vs throwaway is labelled in the script.

### 4. Run the proof
- In Jenkins: New Item → **Pipeline** named `p16-proof` → Pipeline from SCM → the `p16-proof` repo
  (**public** — checked out anonymously, no credential) → enable **GitHub hook trigger for GITScm polling**.
- Push any commit to `p16-proof` (or click "Build Now"). The pipeline
  (`docs/p16/Jenkinsfile.p16-proof`) proves all six "done means":
  1. webhook → build · 2. `aws sts` shows `modelmatch-jenkins-role`, no static keys ·
  3. reads `modelmatch-jenkins-p16-proof-webhook-hmac` via the plugin · 4. **pushes** a throwaway tag to ECR ·
  5. writes `ci/p16-proof` to gitops via the deploy key · 6. `bedrock converse` on Nova Lite.

> **SSH credential pattern (standard for all ModelMatch Jenkinsfiles):** bind the key with
> `withCredentials([sshUserPrivateKey(credentialsId: …, keyFileVariable: 'KEY', usernameVariable: 'USER')])`
> and pass it via `GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes …"`. **Do not** use the `sshagent`
> step / SSH Agent plugin (it is "up for adoption"); we deliberately don't install it.

> **Proof scope:** stage 4 proves **ECR push**, not delete — the instance role has no
> `ecr:BatchDeleteImage`. Remove the throwaway tag in the cutover cleanup (step 5).

> **As run 2026-06-15 — PROOF GREEN (twice).** Build **#1** (manual "Build Now") and build **#2**
> (auto-triggered by a real push webhook, delivery `200`) both **SUCCESS**, all six stages: instance-role
> auth `assumed-role/modelmatch-jenkins-role/i-0b8513065f06a4324` (no static keys) · HMAC read via the
> plugin · ECR push (`modelmatch-backend:p16-proof-1`/`-2`, digest `da80daa3…`) · gitops write
> (branch `ci/p16-proof`, deploy key, all git/host strings masked) · Bedrock Nova
> (`apac.amazon.nova-lite-v1:0` replied `Ok`). The 4 secrets surfaced in the Credentials Provider with
> correct types (3 sshUserPrivateKey + 1 string).
>
> **Bootstrap-secrets fix learned:** AWS **tag values** allow only `[A-Za-z0-9 _.:/=+-@]` — the original
> `jenkins:credentials:description` tag `…(throwaway)` had parentheses and was rejected by the tagging
> service mid-run. Fixed (plain tag value) + made the script **idempotent** (skip-if-exists on every
> secret/deploy-key/repo/webhook) so a resume completed the throwaway tail without re-creating the 3
> already-good persistent pairs.

### 5. Cutover (after the proof is green, GATED)
- **EIP:** keep the fresh TF EIP (update any references) **or** reassociate `15.206.12.120`:
  `aws ec2 disassociate-address` (old assoc) → import into `module.jenkins.aws_eip.this` → reassociate.
- **Terminate the old smoke box** (it's been replaced and backed up):
  `aws ec2 terminate-instances --instance-ids i-0f701eeb64a1d2bbd` and release its now-free EIP if not reused.
- **Orphan ritual:** no unattached EIP/EBS/ELB/NAT; the new EIP + the `prevent_destroy` JENKINS_HOME
  volume are attached (not orphans).
- **Two cleanup scopes — KEEP the persistent CI credentials, DELETE only the throwaway proof resources:**
  - **KEEP (persistent — P17/P18 reuse):** the Secrets Manager secrets `modelmatch-jenkins-frontend-read-key`,
    `modelmatch-jenkins-backend-read-key`, `modelmatch-jenkins-gitops-deploy-key`, and their three GitHub
    deploy keys. **Do not delete these in proof cleanup.**
  - **DELETE (throwaway P16 proof):**
    - `gh repo delete Steve-droid/p16-proof --yes`
    - `git push origin --delete ci/p16-proof` on gitops
    - `aws secretsmanager delete-secret --region ap-south-1 --secret-id modelmatch-jenkins-p16-proof-webhook-hmac --force-delete-without-recovery`
    - the throwaway ECR tag(s) — operator-side (the instance role can't delete):
      `aws ecr batch-delete-image --region ap-south-1 --repository-name modelmatch-backend --image-ids imageTag=p16-proof-<N>` (or leave to the ECR lifecycle policy).

> **As run 2026-06-15 — CUTOVER DONE.** Kept the fresh EIP **`3.6.214.36`**. Terminated the old smoke box
> `i-0f701eeb64a1d2bbd`; its EIP `15.206.12.120` (`eipalloc-0a69f97024b95cae6`) auto-disassociated on
> terminate, then **released**. Deleted the throwaway proof resources: HMAC secret (force-delete),
> gitops `ci/p16-proof` branch, ECR tags `p16-proof-1`+`-2`. **Backup AMI `ami-09b7b3c1bf00385f4`
> retained** as the recovery point. **Orphan ritual CLEAN:** zero unattached EIP / available EBS / ELB /
> NAT; new box `i-0b8513065f06a4324` running with `3.6.214.36` + JENKINS_HOME `vol-051e69f928d0ae33f`
> attached. **KEPT (persistent):** the 3 SSH secrets + their 3 GitHub deploy keys. Two cleanups done
> operator-side (gh token lacks `delete_repo`): the public `p16-proof` repo + the `p16-proof` Jenkins job.

- **Survives `platform` destroy:** separate root, separate state, default VPC — a `platform` destroy
  never references `jenkins/`. Verify by leaving `jenkins/` up across a `platform` apply→destroy cycle.
- **Intentional teardown** (only when truly retiring CI): drop `prevent_destroy` on `aws_ebs_volume`,
  then `terraform -chdir=jenkins destroy -var-file=dev.tfvars`; the EBS + EIP are released. Snapshot the
  EBS first if the job history matters.

## File map

```
modelmatch-infra/
├── jenkins/                         # the persistent CI-controller root (state key jenkins/)
│   ├── versions/providers/backend.tf
│   ├── variables.tf (defaultless) · dev.tfvars (committed, non-secret)
│   ├── iam.tf      # instance-role policy (Bedrock + ECR push + modelmatch-jenkins-* read)
│   ├── main.tf · outputs.tf
├── modules/jenkins-controller/      # our own module (SG, role+profile, EBS, instance, EIP, user_data)
│   └── user_data.sh.tftpl
└── docs/
    ├── p16-jenkins-controller.md    # this runbook
    └── p16/
        ├── Jenkinsfile.p16-proof    # the 6-check proof pipeline (throwaway p16-proof repo)
        └── bootstrap-secrets.sh     # out-of-band secret + deploy-key + webhook bootstrap
```
