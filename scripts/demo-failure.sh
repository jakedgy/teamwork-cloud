#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics

SERVICE=${SERVICE:-${1:-}}
statefulset=$(statefulset_for_service "$SERVICE")
require_commands aws kubectl
load_state
verify_current_account
[[ -z $FAILED_SERVICE ]] || die "A failure is already active for $FAILED_SERVICE; restore it first"
confirm_action "scale $SERVICE to zero replicas" "$CLUSTER_NAME"
kubectl scale statefulset "$statefulset" --replicas=0 --namespace twc-lab
kubectl rollout status "statefulset/$statefulset" --namespace twc-lab --timeout=15m
FAILED_SERVICE=$SERVICE
write_state
log "$SERVICE is stopped; run scripts/demo-restore.sh to restore it"
