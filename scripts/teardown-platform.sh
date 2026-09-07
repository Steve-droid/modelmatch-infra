#!/usr/bin/env bash
# teardown-platform.sh — tear down the EPHEMERAL platform/ stack WITHOUT cluster auth.
#
# This is the June "nodes=0 streamlined" teardown (README §"Teardown & orphan check") as a script, so it
# can run unattended from CodeBuild — the P34b budget kill switch (Budgets 90% ACTUAL → SNS → Lambda →
# CodeBuild) and the P47 final teardown both run exactly this file. It also runs from a laptop.
#
# Why no cluster auth: the EKS public endpoint is allow-listed to Steve's IP and the build role is not an
# EKS access entry, so nothing here talks to the Kubernetes API. Everything goes through the AWS API +
# Terraform state:
#   0. scale the managed node group to 0 and wait for the instances to go (kills the in-cluster CCM/CSI
#      so they cannot re-create the load balancer we delete next — reproduces the nodes=0 state)
#   1. delete the ingress NLB the CCM created (not in Terraform state; found by cluster/service tag)
#   2. `terraform state rm` the in-cluster-only resources (helm releases + namespaces) — they die with
#      the cluster and skip the known ~5-min Helm-uninstall stall
#   3. `terraform destroy` platform/
#   4. delete the detached CSI EBS volumes (CNPG PVCs, reclaimPolicy Delete but no CSI left to do it)
#   5. orphan check: NAT GWs / unattached EIPs / load balancers / available EBS volumes (print only)
#
# DRY_RUN=1 (the DEFAULT — fail-safe): every step is read-only: describe/list + `terraform plan -destroy`.
# DRY_RUN=0: the real teardown. The platform stays up until ~2026-09-28; live-fire is the kill switch or P47.
#
# Every wait is bounded (cap + interval) and prints a TIMEOUT marker instead of hanging. Exit code is the
# first failure; the last line is always `teardown-platform: rc=<n>`.
#
# Inputs (env): DRY_RUN (default 1) · AWS_REGION (default ap-south-1) · TF_VAR_FILE (default dev.tfvars)
# Needs: aws · jq · terraform (>= 1.10, S3-native state lock) · credentials on the default chain.
set -euo pipefail

DRY_RUN="${DRY_RUN:-1}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
TF_VAR_FILE="${TF_VAR_FILE:-dev.tfvars}"
export AWS_DEFAULT_REGION="$AWS_REGION"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_DIR="$REPO_ROOT/platform"
TF=(terraform "-chdir=$PLATFORM_DIR")

# The in-cluster-only resources the destroy must not wait on (README: the Helm-uninstall stall).
STATE_RM_ADDRESSES=(
  'helm_release.argocd_apps'
  'helm_release.argocd'
  'kubernetes_namespace.this["app"]'
  'kubernetes_namespace.this["argocd"]'
  'kubernetes_namespace.this["logging"]'
  'kubernetes_namespace.this["monitoring"]'
)

# Bounded-poll caps (seconds). Never raise these to "fix" a stall — inspect the blocker instead.
NODES_GONE_CAP=600
NLB_GONE_CAP=300
EBS_AVAILABLE_CAP=300
POLL_INTERVAL=15

if [[ "$DRY_RUN" == "1" ]]; then MODE=DRY_RUN; else MODE=LIVE; fi

START_TS=$(date +%s)
log()  { printf '[%s +%04ds] %s\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - START_TS ))" "$*"; }
step() { printf '\n===== %s =====\n' "$*"; }
would() { log "DRY_RUN=1 → would: $*"; }
finish() { local rc=$?; printf '\nteardown-platform: mode=%s rc=%d elapsed=%ds\n' "$MODE" "$rc" "$(( $(date +%s) - START_TS ))"; exit "$rc"; }
trap finish EXIT

# poll_until <cap-seconds> <label> <command...>  — runs the command every POLL_INTERVAL until it exits 0.
# Returns 1 and prints a TIMEOUT marker when the cap is reached.
poll_until() {
  local cap=$1 label=$2; shift 2
  local waited=0
  while ! "$@"; do
    if (( waited >= cap )); then
      log "TIMEOUT after ${cap}s waiting for: $label"
      return 1
    fi
    sleep "$POLL_INTERVAL"; waited=$(( waited + POLL_INTERVAL ))
    log "waiting (${waited}s/${cap}s): $label"
  done
}

step "0/6 preflight (mode=$MODE, region=$AWS_REGION)"
log "identity: $(aws sts get-caller-identity --query 'Arn' --output text)"
log "terraform: $(terraform version -json | jq -r .terraform_version)"
if [[ "$MODE" == LIVE ]]; then
  log "LIVE MODE — this destroys the platform/ stack. bootstrap/ and jenkins/ are untouched."
fi

# terraform init + the cluster facts from state (no cluster call). `output` reads state only.
"${TF[@]}" init -input=false -no-color >/dev/null
if [[ -z "$("${TF[@]}" state list -no-color 2>/dev/null)" ]]; then
  log "platform state is empty — nothing to tear down (already destroyed). Exiting 0."
  exit 0
fi
CLUSTER_NAME="$("${TF[@]}" output -raw cluster_name)"
NODEGROUP_NAME="$("${TF[@]}" output -raw node_group_name)"
NAT_GATEWAY_ID="$("${TF[@]}" output -raw nat_gateway_id)"
log "cluster=$CLUSTER_NAME nodegroup=$NODEGROUP_NAME nat=$NAT_GATEWAY_ID"

# ---------------------------------------------------------------------------------------------------
step "1/6 scale node group to 0 (kills CCM/CSI so they cannot re-create what we delete)"
ng_json="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
            --query 'nodegroup.{status:status,scaling:scalingConfig}' --output json)"
log "nodegroup: $(jq -c . <<<"$ng_json")"
running_nodes() {
  aws ec2 describe-instances \
    --filters "Name=tag:eks:nodegroup-name,Values=$NODEGROUP_NAME" \
              "Name=instance-state-name,Values=pending,running,shutting-down,stopping" \
    --query 'Reservations[].Instances[].InstanceId' --output text | wc -w | tr -d ' '
}
log "node instances alive: $(running_nodes)"
if [[ "$MODE" == LIVE ]]; then
  aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
    --scaling-config minSize=0,maxSize=1,desiredSize=0 --query 'update.id' --output text
  nodes_gone() { [[ "$(running_nodes)" == "0" ]]; }
  poll_until "$NODES_GONE_CAP" "node instances terminated" nodes_gone \
    || true   # a TIMEOUT here is not fatal: the destroy below deletes the node group anyway
else
  would "update-nodegroup-config min=0 max=1 desired=0, then poll (cap ${NODES_GONE_CAP}s) until 0 instances"
fi

# ---------------------------------------------------------------------------------------------------
step "2/6 delete the ingress load balancer (CCM-created, not in Terraform state)"
# Find by the tags the in-tree CCM stamps: kubernetes.io/cluster/<name>=owned. Both v2 (NLB) and classic.
find_cluster_lbs() {
  local arns
  arns="$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text)"
  [[ -z "$arns" ]] && return 0
  # shellcheck disable=SC2086
  aws elbv2 describe-tags --resource-arns $arns --output json \
    | jq -r --arg k "kubernetes.io/cluster/$CLUSTER_NAME" \
        '.TagDescriptions[] | select(any(.Tags[]; .Key == $k)) | .ResourceArn'
}
find_cluster_clbs() {
  local names
  names="$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text)"
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  aws elb describe-tags --load-balancer-names $names --output json \
    | jq -r --arg k "kubernetes.io/cluster/$CLUSTER_NAME" \
        '.TagDescriptions[] | select(any(.Tags[]; .Key == $k)) | .LoadBalancerName'
}
lb_arns="$(find_cluster_lbs)"; clb_names="$(find_cluster_clbs)"
log "cluster-tagged v2 LBs: $(wc -w <<<"$lb_arns" | tr -d ' ')  classic: $(wc -w <<<"$clb_names" | tr -d ' ')"
for arn in $lb_arns; do
  svc="$(aws elbv2 describe-tags --resource-arns "$arn" --output json \
         | jq -r '.TagDescriptions[0].Tags[] | select(.Key=="kubernetes.io/service-name") | .Value')"
  log "  $arn (service ${svc:-?})"
  if [[ "$MODE" == LIVE ]]; then
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn"
    lb_gone() { ! aws elbv2 describe-load-balancers --load-balancer-arns "$arn" >/dev/null 2>&1; }
    poll_until "$NLB_GONE_CAP" "load balancer deleted" lb_gone
  else
    would "elbv2 delete-load-balancer $arn, then poll (cap ${NLB_GONE_CAP}s) until gone"
  fi
done
for name in $clb_names; do
  log "  classic $name"
  if [[ "$MODE" == LIVE ]]; then
    aws elb delete-load-balancer --load-balancer-name "$name"
  else
    would "elb delete-load-balancer $name"
  fi
done

# ---------------------------------------------------------------------------------------------------
step "3/6 terraform state rm the in-cluster-only resources (skip the Helm-uninstall stall)"
state_list="$("${TF[@]}" state list -no-color)"
for addr in "${STATE_RM_ADDRESSES[@]}"; do
  if grep -qxF "$addr" <<<"$state_list"; then
    if [[ "$MODE" == LIVE ]]; then
      "${TF[@]}" state rm -no-color "$addr"
    else
      would "terraform state rm '$addr'"
    fi
  else
    log "  not in state (already removed): $addr"
  fi
done

# ---------------------------------------------------------------------------------------------------
step "4/6 terraform destroy platform/ (-var-file=$TF_VAR_FILE)"
if [[ "$MODE" == LIVE ]]; then
  "${TF[@]}" destroy -var-file="$TF_VAR_FILE" -auto-approve -input=false -no-color
else
  # -refresh=false: the helm/kubernetes resources are still in state in a dry run and refreshing them
  # would need the cluster API (which this runner cannot reach by design). -lock=false: read-only.
  plan_out="$("${TF[@]}" plan -destroy -var-file="$TF_VAR_FILE" -refresh=false -lock=false -input=false -no-color)"
  grep -E '^\s+# .* will be destroyed' <<<"$plan_out" | sed 's/^ *# //; s/ will be destroyed//' | sort | sed 's/^/  - /'
  log "$(grep -E '^Plan:' <<<"$plan_out" || echo 'Plan: (no summary line)')"
fi

# ---------------------------------------------------------------------------------------------------
step "5/6 delete detached CSI EBS volumes (CNPG PVCs; the CSI driver is gone with the nodes)"
csi_volumes() {  # $1 = status filter
  aws ec2 describe-volumes \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" "Name=status,Values=$1" \
    --query 'Volumes[].VolumeId' --output text
}
log "cluster-tagged volumes: in-use=$(csi_volumes in-use | wc -w | tr -d ' ') available=$(csi_volumes available | wc -w | tr -d ' ')"
if [[ "$MODE" == LIVE ]]; then
  volumes_detached() { [[ -z "$(csi_volumes in-use)" ]]; }
  poll_until "$EBS_AVAILABLE_CAP" "cluster-tagged volumes detached" volumes_detached || true
  for vol in $(csi_volumes available); do
    log "  delete-volume $vol"; aws ec2 delete-volume --volume-id "$vol"
  done
else
  for vol in $(csi_volumes in-use) $(csi_volumes available); do
    would "wait until detached, then ec2 delete-volume $vol"
  done
fi

# ---------------------------------------------------------------------------------------------------
step "6/6 orphan check (print only) — expect all 0 after a LIVE run; a DRY_RUN shows the live platform"
nat_count=$(aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting --query 'length(NatGateways)' --output text)
eip_count=$(aws ec2 describe-addresses --query 'length(Addresses[?AssociationId==null])' --output text)
lb_count=$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)
clb_count=$(aws elb describe-load-balancers --query 'length(LoadBalancerDescriptions)' --output text)
ebs_count=$(aws ec2 describe-volumes --filters Name=status,Values=available --query 'length(Volumes)' --output text)
printf '  NAT gateways (not deleted): %s\n  unattached EIPs:            %s\n  load balancers (v2/classic): %s/%s\n  available EBS volumes:      %s\n' \
  "$nat_count" "$eip_count" "$lb_count" "$clb_count" "$ebs_count"
if [[ "$MODE" == LIVE ]]; then
  if [[ "$nat_count$eip_count$lb_count$clb_count$ebs_count" == "00000" ]]; then
    log "ORPHAN CHECK: OK — nothing stray. bootstrap/ + jenkins/ untouched."
  else
    log "ORPHAN CHECK: ATTENTION — non-zero counts above; inspect by tag stack=platform."
  fi
else
  log "ORPHAN CHECK: informational only in DRY_RUN (platform is up, so NAT=1 / LB=1 are expected)."
fi
