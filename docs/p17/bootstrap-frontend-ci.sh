#!/usr/bin/env bash
# P17 — out-of-band bootstrap of the frontend pipeline's two NEW persistent credentials.
# GATED: creates an AWS Secrets Manager secret + a GitHub deploy key + a webhook. Run ONCE,
# after the P17 Jenkinsfile is on the repo, with Steve's explicit OK. Mirrors the P16
# bootstrap-secrets.sh pattern exactly:
#   - secrets reach AWS via --secret-string file://… (NEVER on the argv, never echoed)
#   - private key + HMAC live in 0600 files under a 0700 mktemp dir, removed at exit
#   - the box's AWS identity is the instance profile; these are GIT creds, a SEPARATE identity
#   - idempotent: skip-if-exists on the secret, the deploy key (by title), and the webhook (by URL)
#
# Usage:  ./bootstrap-frontend-ci.sh http://<jenkins-eip>:8080/github-webhook/
#
# Creates (BOTH PERSISTENT — P17 reuses them every run; NOT throwaway):
#   modelmatch-jenkins-frontend-deploy-key   -> WRITE deploy key on Steve-droid/modelmatch-frontend
#       Used ONLY in the main release tail to push the annotated SemVer git tag. Distinct from
#       the existing modelmatch-jenkins-frontend-READ-key (checkout) — title "…(write)" vs "…(read)".
#   modelmatch-jenkins-frontend-webhook-hmac -> the FE repo's webhook HMAC (Secret text credential)
#
# Plus the GitHub webhook on modelmatch-frontend -> the Jenkins controller (push + pull_request),
# authenticated with the HMAC above.
#
# Secret names are FLAT/slash-free — the Credentials Provider plugin uses the secret name as the
# Jenkins credential ID and forbids "/" ([a-zA-Z0-9_.-]+ only).

set -euo pipefail

WEBHOOK_URL="${1:?usage: bootstrap-frontend-ci.sh <jenkins github-webhook URL>}"
REGION="ap-south-1"
OWNER="Steve-droid"
REPO="modelmatch-frontend"
PREFIX="modelmatch-jenkins"

WORK="$(mktemp -d)"; chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> generating the FE write keypair + webhook HMAC into $WORK (0700, removed on exit)"
ssh-keygen -t ed25519 -N '' -C 'modelmatch-jenkins frontend write' -f "$WORK/frontend-deploy" -q
openssl rand -hex 32 > "$WORK/frontend-hmac"; chmod 600 "$WORK/frontend-hmac"

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

# ============================ the FE WRITE deploy key ============================
# Release-tail only: pushes the annotated SemVer git tag. Title differs from the read key so both
# coexist on modelmatch-frontend.
echo "==> creating the WRITE SSH-key secret $PREFIX-frontend-deploy-key (file://, never argv)"
put_ssh_secret "$PREFIX-frontend-deploy-key" "$WORK/frontend-deploy" "WRITE deploy key: modelmatch-frontend"

echo "==> adding the WRITE GitHub deploy key on $REPO"
add_deploy_key "$WORK/frontend-deploy.pub" "$REPO" "modelmatch-jenkins (write)" --allow-write

# ============================ the FE webhook HMAC ============================
# Persistent Secret-text credential. jenkins:credentials:type=string -> surfaces as "Secret text".
# AWS tag values allow only [A-Za-z0-9 _.:/=+-@] — keep the description tag plain (no parens/commas).
echo "==> creating the webhook HMAC secret $PREFIX-frontend-webhook-hmac"
if aws secretsmanager describe-secret --region "$REGION" --secret-id "$PREFIX-frontend-webhook-hmac" >/dev/null 2>&1; then
  echo "    exists, skipping $PREFIX-frontend-webhook-hmac"
else
  aws secretsmanager create-secret \
    --region "$REGION" \
    --name "$PREFIX-frontend-webhook-hmac" \
    --description "modelmatch-frontend GitHub webhook HMAC - persistent (P17)" \
    --secret-string "file://$WORK/frontend-hmac" \
    --tags '[{"Key":"owner","Value":"steve"},{"Key":"project","Value":"modelmatch"},{"Key":"environment","Value":"dev"},{"Key":"stack","Value":"jenkins"},{"Key":"jenkins:credentials:type","Value":"string"},{"Key":"jenkins:credentials:description","Value":"modelmatch-frontend webhook HMAC"}]' >/dev/null
  echo "    created $PREFIX-frontend-webhook-hmac"
fi

# ============================ the GitHub webhook ============================
# Push + pull_request events -> the controller. Config goes in via --input (a 0600 JSON file) so the
# HMAC is never on the argv. Idempotent by URL.
echo "==> creating the GitHub webhook on $REPO -> $WEBHOOK_URL"
if gh api "repos/$OWNER/$REPO/hooks" --jq '.[].config.url' 2>/dev/null | grep -qxF "$WEBHOOK_URL"; then
  echo "    webhook -> $WEBHOOK_URL already present, skipping"
else
  cat > "$WORK/hook.json" <<JSON
{"name":"web","active":true,"events":["push","pull_request"],"config":{"url":"$WEBHOOK_URL","content_type":"json","insecure_ssl":"0","secret":"$(cat "$WORK/frontend-hmac")"}}
JSON
  chmod 600 "$WORK/hook.json"
  gh api -X POST "repos/$OWNER/$REPO/hooks" --input "$WORK/hook.json" >/dev/null
  echo "    webhook -> $WEBHOOK_URL"
fi

echo "==> done."
echo "    PERSISTENT (keep): $PREFIX-frontend-deploy-key (write) + its GitHub deploy key,"
echo "                       $PREFIX-frontend-webhook-hmac, the modelmatch-frontend webhook."
echo "    Next (Jenkins UI): confirm both credentials appear in the Credentials Provider, then create"
echo "    the Multibranch Pipeline job (Git source = git@github.com:$OWNER/$REPO.git via the READ key;"
echo "    Jenkinsfile = Jenkinsfile; enable the GitHub hook trigger) and push to a feature/* branch."
