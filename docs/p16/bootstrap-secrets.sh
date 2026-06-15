#!/usr/bin/env bash
# P16 — out-of-band bootstrap of the Jenkins pipeline credentials. GATED: creates AWS Secrets Manager
# secrets + GitHub deploy keys + the throwaway p16-proof repo & webhook. Run ONCE, after the jenkins/
# apply, with Steve's explicit OK. Mirrors the P12 modelmatch/app pattern:
#   - secrets reach AWS via --secret-string file://… (NEVER on the argv, never echoed)
#   - private keys live in 0600 temp files under a 0700 mktemp dir, removed at the end
#   - the box's AWS identity is the instance profile; these are GIT/registry creds, a SEPARATE identity
#
# Usage:  ./bootstrap-secrets.sh http://<jenkins-eip>:8080/github-webhook/
#
# TWO LIFECYCLES (keep them separate — see the cleanup section of the runbook):
#
#   PERSISTENT CI credentials  — survive P16; P17/P18 reuse them. DO NOT delete in proof cleanup.
#     modelmatch-jenkins-frontend-read-key  -> READ  deploy key on Steve-droid/modelmatch-frontend (PRIVATE)
#     modelmatch-jenkins-backend-read-key   -> READ  deploy key on Steve-droid/modelmatch-backend  (PRIVATE)
#     modelmatch-jenkins-gitops-deploy-key  -> WRITE deploy key on Steve-droid/modelmatch-gitops    (PUBLIC)
#     (future per-repo FE/BE webhook HMACs are added by P17/P18, not here.)
#
#   THROWAWAY P16 proof resources — delete once the proof is green:
#     modelmatch-jenkins-p16-proof-webhook-hmac  -> proof-only webhook HMAC (NOT the FE/BE HMACs)
#     public Steve-droid/p16-proof repo + its webhook
#     (also throwaway, created by the proof RUN: the ci/p16-proof gitops branch + any ECR p16-proof tag)
#
# Secret names are FLAT/slash-free — the Credentials Provider plugin uses the secret name as the Jenkins
# credential ID and forbids "/" ([a-zA-Z0-9_.-]+ only). demo BYOK + public-registry creds are P18/P19.

set -euo pipefail

WEBHOOK_URL="${1:?usage: bootstrap-secrets.sh <jenkins github-webhook URL>}"
REGION="ap-south-1"
OWNER="Steve-droid"
PREFIX="modelmatch-jenkins" # FLAT/slash-free: the plugin uses the secret name as the credential ID

WORK="$(mktemp -d)"; chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> generating keypairs + proof HMAC into $WORK (0700, removed on exit)"
ssh-keygen -t ed25519 -N '' -C 'modelmatch-jenkins frontend read'  -f "$WORK/frontend-read" -q
ssh-keygen -t ed25519 -N '' -C 'modelmatch-jenkins backend read'   -f "$WORK/backend-read"  -q
ssh-keygen -t ed25519 -N '' -C 'modelmatch-jenkins gitops write'   -f "$WORK/gitops-deploy" -q
openssl rand -hex 32 > "$WORK/proof-hmac"; chmod 600 "$WORK/proof-hmac"

# --- helper: create an SSH-private-key secret tagged for the Credentials Provider plugin ----------
# The plugin turns a secret tagged jenkins:credentials:type=sshUserPrivateKey into an SSH credential
# whose Jenkins credential ID == the secret NAME, with username from jenkins:credentials:username.
put_ssh_secret() {
  local name="$1" keyfile="$2" desc="$3"
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" >/dev/null 2>&1; then
    echo "    exists, skipping $name"; return 0
  fi
  aws secretsmanager create-secret \
    --region "$REGION" \
    --name "$name" \
    --description "$desc" \
    --secret-string "file://$keyfile" \
    --tags "$(python3 - "$desc" <<'PY'
import json,sys
desc=sys.argv[1]
common=[{"Key":"owner","Value":"steve"},{"Key":"project","Value":"modelmatch"},{"Key":"environment","Value":"dev"},{"Key":"stack","Value":"jenkins"}]
plugin=[{"Key":"jenkins:credentials:type","Value":"sshUserPrivateKey"},{"Key":"jenkins:credentials:username","Value":"git"},{"Key":"jenkins:credentials:description","Value":desc}]
print(json.dumps(common+plugin))
PY
)" >/dev/null
  echo "    created $name"
}

# --- helper: add a GitHub deploy key idempotently (skip if one with this title already exists) -----
# Re-runs regenerate keys into a fresh temp dir, so we skip by TITLE (unique per repo), not by content,
# keeping the already-stored secret paired with the deploy key created alongside it on the first run.
add_deploy_key() {
  local pubfile="$1" repo="$2" title="$3"; shift 3
  if gh api "repos/$OWNER/$repo/keys" --jq '.[].title' 2>/dev/null | grep -qxF "$title"; then
    echo "    deploy key '$title' already on $repo, skipping"; return 0
  fi
  gh repo deploy-key add "$pubfile" --repo "$OWNER/$repo" --title "$title" "$@"
}

# ============================ PERSISTENT CI credentials ============================
# These outlive P16 — P17/P18 check out the private app repos + push the gitops tag bump with them.
echo "==> [persistent] creating SSH-key secrets under $PREFIX-* (file://, never argv)"
put_ssh_secret "$PREFIX-frontend-read-key" "$WORK/frontend-read" "Read deploy key: modelmatch-frontend"
put_ssh_secret "$PREFIX-backend-read-key"  "$WORK/backend-read"  "Read deploy key: modelmatch-backend"
put_ssh_secret "$PREFIX-gitops-deploy-key" "$WORK/gitops-deploy" "WRITE deploy key: modelmatch-gitops"

echo "==> [persistent] adding GitHub deploy keys (read for the private app repos, write for gitops)"
add_deploy_key "$WORK/frontend-read.pub" modelmatch-frontend "modelmatch-jenkins (read)"
add_deploy_key "$WORK/backend-read.pub"  modelmatch-backend  "modelmatch-jenkins (read)"
add_deploy_key "$WORK/gitops-deploy.pub" modelmatch-gitops   "modelmatch-jenkins (write)" --allow-write

# ============================ THROWAWAY P16 proof resources =======================
# Proof-ONLY HMAC (NOT the future FE/BE webhook HMACs). The plugin needs jenkins:credentials:type=string
# for it to surface as a "Secret text" credential. Deleted in the proof cleanup.
echo "==> [throwaway] creating proof-only webhook HMAC $PREFIX-p16-proof-webhook-hmac"
# NOTE: AWS *tag values* allow only [A-Za-z0-9 _.:/=+-@] — no parentheses/commas. Keep the
# jenkins:credentials:description tag plain; the longer prose lives in --description (less restricted).
if aws secretsmanager describe-secret --region "$REGION" --secret-id "$PREFIX-p16-proof-webhook-hmac" >/dev/null 2>&1; then
  echo "    exists, skipping $PREFIX-p16-proof-webhook-hmac"
else
  aws secretsmanager create-secret \
    --region "$REGION" \
    --name "$PREFIX-p16-proof-webhook-hmac" \
    --description "P16 proof-only webhook HMAC - throwaway, delete after the proof is green" \
    --secret-string "file://$WORK/proof-hmac" \
    --tags '[{"Key":"owner","Value":"steve"},{"Key":"project","Value":"modelmatch"},{"Key":"environment","Value":"dev"},{"Key":"stack","Value":"jenkins"},{"Key":"lifecycle","Value":"throwaway-p16-proof"},{"Key":"jenkins:credentials:type","Value":"string"},{"Key":"jenkins:credentials:description","Value":"P16 proof-only webhook HMAC - throwaway"}]' >/dev/null
  echo "    created $PREFIX-p16-proof-webhook-hmac"
fi

# PUBLIC throwaway proof repo: only a Jenkinsfile + README (no secrets) -> Jenkins checks it out
# ANONYMOUSLY (no extra read deploy key). Deleted once P16 is green.
echo "==> [throwaway] creating public p16-proof repo + webhook"
PROOF="$WORK/p16-proof"
mkdir -p "$PROOF"
cp "$(dirname "$0")/Jenkinsfile.p16-proof" "$PROOF/Jenkinsfile"
cat > "$PROOF/README.md" <<'MD'
# p16-proof (throwaway, public)
Minimal PUBLIC repo whose webhook triggers the P16 proof pipeline on the ModelMatch Jenkins
controller. Contains no secrets; Jenkins checks it out anonymously. Delete after P16 is green:
`gh repo delete Steve-droid/p16-proof --yes`.
MD
( cd "$PROOF" && git init -q && git add . && git -c user.email=jenkins@modelmatch.ci -c user.name=modelmatch-jenkins commit -qm "chore: P16 proof pipeline" )
if gh repo view "$OWNER/p16-proof" >/dev/null 2>&1; then
  echo "    repo $OWNER/p16-proof exists, skipping create/push"
else
  gh repo create "$OWNER/p16-proof" --public --source "$PROOF" --push --description "Throwaway P16 webhook to build proof"
fi

# Webhook config goes in via --input (a 0600 JSON file) so the HMAC is never on the argv.
if gh api "repos/$OWNER/p16-proof/hooks" --jq '.[].config.url' 2>/dev/null | grep -qxF "$WEBHOOK_URL"; then
  echo "    webhook -> $WEBHOOK_URL already present, skipping"
else
  cat > "$WORK/hook.json" <<JSON
{"name":"web","active":true,"events":["push"],"config":{"url":"$WEBHOOK_URL","content_type":"json","insecure_ssl":"0","secret":"$(cat "$WORK/proof-hmac")"}}
JSON
  chmod 600 "$WORK/hook.json"
  gh api -X POST "repos/$OWNER/p16-proof/hooks" --input "$WORK/hook.json" >/dev/null
  echo "    webhook -> $WEBHOOK_URL"
fi

echo "==> done."
echo "    PERSISTENT (keep): $PREFIX-{frontend-read,backend-read,gitops-deploy}-key + their GitHub deploy keys"
echo "    THROWAWAY (delete after green): $PREFIX-p16-proof-webhook-hmac, the p16-proof repo + webhook"
echo "    Next: in Jenkins confirm the 4 credentials appear (Credentials Provider), create the p16-proof"
echo "    Pipeline job (SCM = the public repo, 'GitHub hook trigger'), and push to it."
