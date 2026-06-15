#!/usr/bin/env bash
# P18 — out-of-band bootstrap of the BACKEND pipeline's two NEW persistent credentials.
# GATED: creates an AWS Secrets Manager secret + a GitHub deploy key + a webhook. Run ONCE,
# after the P18 Jenkinsfile is on the repo, with Steve's explicit OK. Mirrors the P17
# bootstrap-frontend-ci.sh pattern exactly:
#   - secrets reach AWS via --secret-string file://… (NEVER on the argv, never echoed)
#   - private key + HMAC live in 0600 files under a 0700 mktemp dir, removed at exit
#   - the box's AWS identity is the instance profile; these are GIT creds, a SEPARATE identity
#   - idempotent: skip-if-exists on the secret, the deploy key (by title), and the webhook (by URL)
#
# Usage:  ./bootstrap-backend-ci.sh http://<jenkins-eip>:8080/github-webhook/
#         (current controller: http://3.6.214.36:8080/github-webhook/)
#
# Creates (BOTH PERSISTENT — P18 reuses them every run; NOT throwaway):
#   modelmatch-jenkins-backend-deploy-key   -> WRITE deploy key on Steve-droid/modelmatch-backend
#       Used ONLY in the main release tail to push the annotated SemVer git tag. Distinct from
#       the existing modelmatch-jenkins-backend-READ-key (checkout) — title "…(write)" vs "…(read)".
#   modelmatch-jenkins-backend-webhook-hmac -> the BE repo's webhook HMAC (Secret text credential)
#
# Plus the GitHub webhook on modelmatch-backend -> the Jenkins controller (push + pull_request),
# authenticated with the HMAC above. (The gitops WRITE key + the BE READ key already exist from
# P16 and are reused unchanged.)
#
# Secret names are FLAT/slash-free — the Credentials Provider plugin uses the secret name as the
# Jenkins credential ID and forbids "/" ([a-zA-Z0-9_.-]+ only).

set -euo pipefail

WEBHOOK_URL="${1:?usage: bootstrap-backend-ci.sh <jenkins github-webhook URL>}"
REGION="ap-south-1"
OWNER="Steve-droid"
REPO="modelmatch-backend"
PREFIX="modelmatch-jenkins"

WORK="$(mktemp -d)"; chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> generating the BE write keypair + webhook HMAC into $WORK (0700, removed on exit)"
ssh-keygen -t ed25519 -N '' -C 'modelmatch-jenkins backend write' -f "$WORK/backend-deploy" -q
openssl rand -hex 32 > "$WORK/backend-hmac"; chmod 600 "$WORK/backend-hmac"

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
add_deploy_key() {
  local pubfile="$1" repo="$2" title="$3"; shift 3
  if gh api "repos/$OWNER/$repo/keys" --jq '.[].title' 2>/dev/null | grep -qxF "$title"; then
    echo "    deploy key '$title' already on $repo, skipping"; return 0
  fi
  gh repo deploy-key add "$pubfile" --repo "$OWNER/$repo" --title "$title" "$@"
}

# ============================ the BE WRITE deploy key ============================
# Release-tail only: pushes the annotated SemVer git tag. Title differs from the read key so both
# coexist on modelmatch-backend.
echo "==> creating the WRITE SSH-key secret $PREFIX-backend-deploy-key (file://, never argv)"
put_ssh_secret "$PREFIX-backend-deploy-key" "$WORK/backend-deploy" "WRITE deploy key: modelmatch-backend"

echo "==> adding the WRITE GitHub deploy key on $REPO"
add_deploy_key "$WORK/backend-deploy.pub" "$REPO" "modelmatch-jenkins (write)" --allow-write

# ============================ the BE webhook HMAC ============================
# Persistent Secret-text credential. jenkins:credentials:type=string -> surfaces as "Secret text".
# AWS tag values allow only [A-Za-z0-9 _.:/=+-@] — keep the description tag plain (no parens/commas).
echo "==> creating the webhook HMAC secret $PREFIX-backend-webhook-hmac"
if aws secretsmanager describe-secret --region "$REGION" --secret-id "$PREFIX-backend-webhook-hmac" >/dev/null 2>&1; then
  echo "    exists, skipping $PREFIX-backend-webhook-hmac"
else
  aws secretsmanager create-secret \
    --region "$REGION" \
    --name "$PREFIX-backend-webhook-hmac" \
    --description "modelmatch-backend GitHub webhook HMAC - persistent (P18)" \
    --secret-string "file://$WORK/backend-hmac" \
    --tags '[{"Key":"owner","Value":"steve"},{"Key":"project","Value":"modelmatch"},{"Key":"environment","Value":"dev"},{"Key":"stack","Value":"jenkins"},{"Key":"jenkins:credentials:type","Value":"string"},{"Key":"jenkins:credentials:description","Value":"modelmatch-backend webhook HMAC"}]' >/dev/null
  echo "    created $PREFIX-backend-webhook-hmac"
fi

# ============================ the GitHub webhook ============================
# Push + pull_request events -> the controller. Config goes in via --input (a 0600 JSON file) so the
# HMAC is never on the argv. Idempotent by URL.
echo "==> creating the GitHub webhook on $REPO -> $WEBHOOK_URL"
if gh api "repos/$OWNER/$REPO/hooks" --jq '.[].config.url' 2>/dev/null | grep -qxF "$WEBHOOK_URL"; then
  echo "    webhook -> $WEBHOOK_URL already present, skipping"
else
  cat > "$WORK/hook.json" <<JSON
{"name":"web","active":true,"events":["push","pull_request"],"config":{"url":"$WEBHOOK_URL","content_type":"json","insecure_ssl":"0","secret":"$(cat "$WORK/backend-hmac")"}}
JSON
  chmod 600 "$WORK/hook.json"
  gh api -X POST "repos/$OWNER/$REPO/hooks" --input "$WORK/hook.json" >/dev/null
  echo "    webhook -> $WEBHOOK_URL"
fi

echo "==> done."
echo "    PERSISTENT (keep): $PREFIX-backend-deploy-key (write) + its GitHub deploy key,"
echo "                       $PREFIX-backend-webhook-hmac, the modelmatch-backend webhook."
echo "    Next (Jenkins UI): confirm both credentials appear in the Credentials Provider, then create"
echo "    the Multibranch Pipeline job (Git source = git@github.com:$OWNER/$REPO.git via the READ key"
echo "    modelmatch-jenkins-backend-read-key; Jenkinsfile = Jenkinsfile; enable the GitHub hook"
echo "    trigger) and push to a feature/* branch to validate fast + integration + E2E (fake LLM)."
