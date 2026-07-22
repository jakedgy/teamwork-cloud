#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics

if [[ -f $STATE_FILE ]]; then
  load_state
else
  AWS_REGION=${AWS_REGION:-us-east-2}
  CLUSTER_NAME=${CLUSTER_NAME:-twc-lab}
  DEPLOYMENT_ID=${DEPLOYMENT_ID:-}
  VPC_ID=${VPC_ID:-}
  SUBNET_IDS=${SUBNET_IDS:-}
fi
[[ -n $VPC_ID && -n $SUBNET_IDS ]] || die "VPC_ID and SUBNET_IDS are required to render cluster configuration"
[[ $DEPLOYMENT_ID =~ ^[a-f0-9]{32}$ ]] || die "DEPLOYMENT_ID is required to render cluster configuration"
require_commands aws
ensure_lab_dir
split_csv "$SUBNET_IDS"
rows=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "${CSV_VALUES[@]}" --query 'Subnets[].join(`\t`,[AvailabilityZone,SubnetId])' --output text)
(( $(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ') >= 2 )) || die "Could not discover at least two subnet availability zones"

tmp="$LAB_DIR/.cluster.yaml.tmp.$$"
umask 077
{
  printf 'apiVersion: eksctl.io/v1alpha5\n'
  printf 'kind: ClusterConfig\n'
  printf 'metadata:\n  name: %s\n  region: %s\n  tags:\n    twc-lab:deployment-id: %s\n' "$CLUSTER_NAME" "$AWS_REGION" "$DEPLOYMENT_ID"
  printf 'vpc:\n  id: %s\n  subnets:\n    public:\n' "$VPC_ID"
  while IFS=$'\t' read -r az subnet; do
    [[ -n ${az:-} && -n ${subnet:-} ]] || continue
    printf '      %s:\n        id: %s\n' "$az" "$subnet"
  done <<<"$rows"
  printf 'autoModeConfig:\n  enabled: true\n  nodePools:\n    - general-purpose\n    - system\n'
} >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$CLUSTER_CONFIG"
printf '%s\n' "$CLUSTER_CONFIG"
