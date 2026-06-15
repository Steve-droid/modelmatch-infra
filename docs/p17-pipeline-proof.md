# P17 — Frontend CI pipeline: live-cluster proof (Epic E11)

> **Slice P17 (E11 — CI/CD pipelines), proven 2026-06-15.** The `modelmatch-frontend/Jenkinsfile`
> delivery flow runs end-to-end on the graded persistent Jenkins controller (P16) and the GitOps/ArgoCD
> platform (P9–P15). This note records the **acceptance evidence**: a green feature-branch validation run,
> the `main` release tail, and the live CI→GitOps→ArgoCD→Deployment chain. Region `ap-south-1`, account
> `832285994273`.

## The pipeline (as authored — see `modelmatch-frontend/Jenkinsfile`)

Multibranch job `modelmatch-frontend` on the controller (`http://3.6.214.36:8080`). Every branch runs
validation; only `main` runs the release tail.

```
Source+config -> Build -> Static/dep gate (eslint + tsc; npm audit report-only)
  -> Test (Vitest unit/component) -> Package (FE image) -> Trivy (CRITICAL+HIGH gate)
  -> Integration (Vitest+RTL+MSW, no containers)
  -> E2E (Playwright vs a throwaway compose FE-image+BE+Postgres: empty volume -> migrate+seed
          -> run -> down -v; fake-LLM only, no e2e-live)
  -> [main only] Tag (annotated SemVer) -> Publish (ECR) -> Deploy (gitops frontend.image.tag bump)
```

Identities (no static AWS keys): EC2 instance role `modelmatch-jenkins-role` → ECR login/push;
`modelmatch-jenkins-frontend-deploy-key` (WRITE) → the annotated git tag; `modelmatch-jenkins-gitops-deploy-key`
(WRITE) → the gitops image-tag bump. Tool images (Node/Playwright/Trivy/yq) run as pinned throwaway
containers; stable non-secret config lives in `modelmatch-frontend/ci/pipeline.env`.

## Box prerequisite installed this session

The controller is an Ubuntu-`docker.io` box (Docker `29.1.3-0ubuntu3~24.04.2`, **not** Docker Inc's
`docker-ce` repo), so Docker Inc's `docker-compose-plugin` package is unavailable. Installed Ubuntu's
equivalent from the already-enabled `universe`:

```bash
sudo apt-get update && sudo apt-get install -y docker-compose-v2   # -> docker compose v2.40.3
```

`ci/e2e-stack.sh` auto-detects `docker compose` (v2 plugin) ahead of the v1 standalone, so no pipeline
change was needed. The plugin installs system-wide (`/usr/libexec/docker/cli-plugins/docker-compose`),
available to the `jenkins` service user.

## 1. Feature-branch validation — GREEN

`feature/p17-frontend-pipeline` (HEAD `b5552b9`), build **#7**, all 7 stages SUCCESS. The E2E stage:
`docker compose` brought up Postgres → migrate+seed → backend (`modelmatch-backend:1.0.1` from ECR via
the instance role) → the FE image under test; **backend healthy after 2 attempts**; Playwright ran in its
pinned container with `--network host` (proven on the box for the first time — native Linux host
networking reaches the published compose ports), `E2E_REQUIRE_BACKEND=true`; **1 real-stack smoke test
passed (3.6s)**; `down -v` removed all containers + the pgdata volume + network. Release-tail stages
correctly skipped (`when` branch != main).

## 2. `main` release tail — GREEN

Merged `feature/p17-frontend-pipeline` → `main` with `--no-ff` (merge commit **`c9e84bf`**), pushed; the
1-min multibranch scan auto-built `main` build **#1** (full validation + release tail), SUCCESS:

- **Tag:** annotated **`v1.0.1`** created on `c9e84bf` (`release: v1.0.1 (build 1)`), pushed via the FE
  write deploy key. Computed from git tags (highest was `v1.0.0` → next patch `v1.0.1`); idempotent.
- **Publish:** **`modelmatch-frontend:1.0.1`** pushed to ECR (`832285994273.dkr.ecr.ap-south-1.amazonaws.com/modelmatch-frontend`),
  digest **`sha256:1243017f199e6705863d912e477e0964b0ccec965ad55fecbf2883a81f89e9e5`**, via `aws ecr
  get-login-password` off the instance role — no static AWS keys.
- **Deploy:** cloned `modelmatch-gitops`, `yq`-bumped `charts/modelmatch/values.yaml`
  `frontend.image.tag → 1.0.1`, committed **`0f1dae7`** (`deploy(frontend): image tag -> 1.0.1 (build 1)`),
  pushed to gitops `main` via the gitops deploy key. **No `kubectl`/`helm`** — Deploy is only a gitops commit.

> **yq reflow note:** the first `yq eval -i` deploy normalized `values.yaml` formatting (stripped a few
> blank lines, collapsed inline-comment spacing, re-indented the `frontend.config:` comment block 4→2
> spaces). No comments were lost; the file is now in yq canonical form, so subsequent tag bumps produce a
> clean one-line diff.

## 3. Live-cluster ArgoCD proof — GREEN

Platform stack brought UP for the proof (`terraform -chdir=platform apply -var-file=dev.tfvars`,
41 add / 0 change / 0 destroy): EKS `modelmatch` (k8s 1.36, 2× t3a.medium Ready in private subnets),
new OIDC issuer `70E72ECD…`, ArgoCD installed by Terraform, all **9 App-of-Apps children Synced+Healthy**
(app-secrets, cert-manager, cluster-issuers, cnpg-operator, external-secrets, modelmatch,
modelmatch-postgres, nginx-ingress, root).

Per-rebuild host recompute (the ingress ELB has no static IP): `scripts/recompute-host.sh` set
`global.sslipIp = 35.154.192.87` (new ELB `a6bf38b6560a0432fb1d32e082232aec-…elb.amazonaws.com`),
committed `6dd09c4`, pushed; ArgoCD synced the new hosts and cert-manager issued LE-prod certs.

**Baseline → after, observed live:**

| | Before merge | After release tail |
|---|---|---|
| gitops `frontend.image.tag` | `1.0.0` | `1.0.1` (commit `0f1dae7`) |
| ArgoCD `modelmatch` app revision | `bfa48f7` | `0f1dae7` (detected in **~24s**) |
| FE Deployment image | `modelmatch-frontend:1.0.0` | `modelmatch-frontend:1.0.1` |
| FE pod | Ready (1.0.0) | `modelmatch-frontend-7b4b9f5b97-k4ghx` Ready (1.0.1) |

Ingress serves the rolled app: `curl https://app.35.154.192.87.sslip.io/` → **HTTP 200** with a trusted
Let's Encrypt prod cert (issuer `C=US, O=Let's Encrypt, CN=YR1` — no `-k` needed);
`https://api.35.154.192.87.sslip.io/healthz` → `{"status":"ok"}`.

**Chain proven:** Jenkins (CI) builds + tags + publishes + commits a gitops tag bump → ArgoCD (CD) detects
the commit and rolls the Deployment → the new image serves through the single ingress with valid TLS.
Deploy never touches the cluster directly.

## Teardown

Platform is the daily-destroy stack — `terraform -chdir=platform destroy -var-file=dev.tfvars` after the
proof, with the orphan check (zero stray ELB / unattached EBS / unattached EIP / NAT). **Delete the
`nginx-ingress` ArgoCD app (its CCM-created ELB) and the `modelmatch-postgres` app (its 2 CNPG EBS
volumes) BEFORE the destroy** so the CSI/CCM controllers remove those cloud resources first. `bootstrap/`
(state, budget, ECR `:1.0.1`, ingestion bucket) and `jenkins/` (the controller) are persistent and
untouched.
