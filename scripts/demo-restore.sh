#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics
require_commands aws
load_state
verify_current_account
if [[ -z $FAILED_SERVICE ]]; then
  log "No failed service is recorded; nothing to restore."
  exit 0
fi
require_commands kubectl
statefulset=$(statefulset_for_service "$FAILED_SERVICE")
confirm_action "restore $FAILED_SERVICE to one replica" "$CLUSTER_NAME"
kubectl scale statefulset "$statefulset" --replicas=1 --namespace twc-lab
kubectl rollout status "statefulset/$statefulset" --namespace twc-lab --timeout=15m
FAILED_SERVICE=
write_state
log "Service restored"
