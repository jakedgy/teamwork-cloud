#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics
require_commands aws kubectl
load_state
verify_current_account

cluster_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null || printf 'NOT_FOUND')
ready_pods=$(kubectl get pods --namespace twc-lab --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
all_pods=$(kubectl get pods --namespace twc-lab --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ ${JSON:-0} == 1 ]]; then
  printf '{"account":"%s","region":"%s","cluster":"%s","clusterStatus":"%s","networkMode":"%s","vpc":"%s","subnets":"%s","readyPods":%s,"allPods":%s,"failedService":"%s","nlbHostname":"%s"}\n' \
    "$ACCOUNT_ID" "$AWS_REGION" "$CLUSTER_NAME" "$cluster_status" "$NETWORK_MODE" "$VPC_ID" "$SUBNET_IDS" "$ready_pods" "$all_pods" "$FAILED_SERVICE" "$NLB_HOSTNAME"
else
  printf 'Account:        %s\n' "$ACCOUNT_ID"
  printf 'Region:         %s\n' "$AWS_REGION"
  printf 'Cluster:        %s (%s)\n' "$CLUSTER_NAME" "$cluster_status"
  printf 'Network:        %s (%s)\n' "$NETWORK_MODE" "$VPC_ID"
  printf 'Subnets:        %s\n' "$SUBNET_IDS"
  printf 'Pods:           %s/%s running\n' "$ready_pods" "$all_pods"
  printf 'Failed service: %s\n' "${FAILED_SERVICE:-none}"
  printf 'URL:            http://%s/webapp\n' "${NLB_HOSTNAME:-pending}"
fi
