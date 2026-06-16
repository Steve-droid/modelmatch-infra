#!/usr/bin/env bash
# P19 — out-of-band bootstrap of the AGENT pipeline's ONE new persistent credential:
# the Docker Hub access token used to push the public modelmatch-agent image.
#
# GATED: creates an AWS Secrets Manager secret. Run ONCE, with Steve's explicit OK.
# Mirrors the P17/P18 bootstrap pattern:
#   - the token reaches AWS via --secret-string file://… (NEVER on the argv, never echoed)
#   - idempotent: skip-if-exists on the secret
#   - this is a REGISTRY credential (username+token), a SEPARATE identity from the box's
#     AWS instance profile — never AWS IAM for Docker Hub, never a token in a Jenkinsfile.
#
# The AWS Secrets Manager Credentials Provider plugin turns a secret tagged
# jenkins:credentials:type=usernamePassword into a Jenkins "Username with password"
# credential whose ID == the secret NAME, username from jenkins:credentials:username,
# password = the SecretString (the Docker Hub token). The agent Jenkinsfile references it
# by ID only (CRED_DOCKERHUB=modelmatch-jenkins-dockerhub).
#
# Secret name is FLAT/slash-free — the plugin uses the name as the credential ID and
# forbids "/" ([a-zA-Z0-9_.-]+ only).
#
# Usage:  ./bootstrap-dockerhub-cred.sh /path/to/dockerhub-token.txt
#         (the token file must contain ONLY the token, no trailing newline)

set -euo pipefail

TOKEN_FILE="${1:?usage: bootstrap-dockerhub-cred.sh <path-to-dockerhub-token-file>}"
REGION="ap-south-1"
NAME="modelmatch-jenkins-dockerhub"
USERNAME="stevelevit"   # Docker Hub account/namespace = docker.io/stevelevit/modelmatch-agent

[ -f "$TOKEN_FILE" ] || { echo "token file not found: $TOKEN_FILE" >&2; exit 1; }
[ -s "$TOKEN_FILE" ] || { echo "token file is empty: $TOKEN_FILE" >&2; exit 1; }

if aws secretsmanager describe-secret --region "$REGION" --secret-id "$NAME" >/dev/null 2>&1; then
  echo "    exists, skipping $NAME"
  exit 0
fi

echo "==> creating the Docker Hub username+token secret $NAME (file://, never argv)"
aws secretsmanager create-secret \
  --region "$REGION" \
  --name "$NAME" \
  --description "Docker Hub access token (read+write) for the agent pipeline public push - persistent (P19)" \
  --secret-string "file://$TOKEN_FILE" \
  --tags '[
    {"Key":"owner","Value":"steve"},
    {"Key":"project","Value":"modelmatch"},
    {"Key":"environment","Value":"dev"},
    {"Key":"stack","Value":"jenkins"},
    {"Key":"jenkins:credentials:type","Value":"usernamePassword"},
    {"Key":"jenkins:credentials:username","Value":"stevelevit"},
    {"Key":"jenkins:credentials:description","Value":"Docker Hub stevelevit push token - agent pipeline"}
  ]' >/dev/null
echo "    created $NAME"

echo "==> done."
echo "    PERSISTENT (keep): $NAME — the public-registry push credential."
echo "    Next (Jenkins UI): confirm the credential appears in the AWS Secrets Manager"
echo "    Credentials Provider, then create the SECOND Multibranch Pipeline job"
echo "    (Git source = git@github.com:Steve-droid/modelmatch-backend.git via the READ key"
echo "    modelmatch-jenkins-backend-read-key; Script Path = Jenkinsfile.agent; enable the"
echo "    GitHub hook trigger — the existing modelmatch-backend webhook already delivers to"
echo "    both jobs). Push feature/p19-agent-pipeline to validate the skipped + forced paths."
