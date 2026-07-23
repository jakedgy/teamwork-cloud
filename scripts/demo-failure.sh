#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics

SERVICE=${SERVICE:-${1:-}}
statefulset=$(statefulset_for_service "$SERVICE")
require_commands aws kubectl
load_state
verify_current_account
[[ -z $FAILED_SERVICE ]] || die "A failure is already active for $FAILED_SERVICE; restore it first"
confirm_action "scale $SERVICE to zero replicas" "$CLUSTER_NAME"
verify_cluster_identity
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
verify_cluster_identity
lab_kubectl scale statefulset "$statefulset" --replicas=0 --namespace twc-lab
FAILED_SERVICE=$SERVICE
write_state
verify_cluster_identity
lab_kubectl rollout status "statefulset/$statefulset" --namespace twc-lab --timeout=15m
log "$SERVICE is stopped; run scripts/demo-restore.sh to restore it"
