#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics
require_commands aws helm kubectl
load_state
verify_current_account

if cluster_lookup=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>&1); then
  cluster_status=$cluster_lookup
elif [[ $cluster_lookup == *ResourceNotFoundException* ]]; then
  cluster_status=NOT_FOUND
else
  cluster_status=UNKNOWN
  log "Unable to query EKS cluster status"
fi
helm_releases=$(helm list --all-namespaces --filter '^(twc-lab|ingress-nginx)$' --output json 2>/dev/null || printf '[]')
pods=$(kubectl get pods --namespace twc-lab --output name 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
pvcs=$(kubectl get persistentvolumeclaims --namespace twc-lab --output name 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
ingress_hostname=$(kubectl get service ingress-nginx-controller --namespace ingress-nginx --output 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
simulator_health=$(kubectl get --raw '/api/v1/namespaces/twc-lab/services/http:twc-lab-simulator:8080/proxy/api/health' 2>/dev/null || printf 'unavailable')
layer_explanation='ingress -> simulator -> backing services -> PVC storage'

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

if [[ ${JSON:-0} == 1 ]]; then
  printf '{"account":"%s","region":"%s","cluster":"%s","clusterStatus":"%s","networkMode":"%s","vpc":"%s","subnets":"%s","helmReleases":%s,"pods":"%s","pvcs":"%s","ingressHostname":"%s","simulatorHealth":"%s","failedService":"%s","layerExplanation":"%s"}\n' \
    "$ACCOUNT_ID" "$AWS_REGION" "$CLUSTER_NAME" "$cluster_status" "$NETWORK_MODE" "$VPC_ID" "$SUBNET_IDS" "$helm_releases" "$(json_escape "$pods")" "$(json_escape "$pvcs")" "$(json_escape "$ingress_hostname")" "$(json_escape "$simulator_health")" "$FAILED_SERVICE" "$layer_explanation"
else
  printf 'Account:        %s\n' "$ACCOUNT_ID"
  printf 'Region:         %s\n' "$AWS_REGION"
  printf 'Cluster:        %s (%s)\n' "$CLUSTER_NAME" "$cluster_status"
  printf 'Network:        %s (%s)\n' "$NETWORK_MODE" "$VPC_ID"
  printf 'Subnets:        %s\n' "$SUBNET_IDS"
  printf 'Helm releases:  %s\n' "$helm_releases"
  printf 'Pods:           %s\n' "${pods:-none}"
  printf 'PVCs:           %s\n' "${pvcs:-none}"
  printf 'Ingress:        %s\n' "${ingress_hostname:-pending}"
  printf 'Simulator health: %s\n' "$simulator_health"
  printf 'Failed service: %s\n' "${FAILED_SERVICE:-none}"
  printf 'Layers:         %s\n' "$layer_explanation"
  printf 'URL:            http://%s/webapp\n' "${ingress_hostname:-pending}"
fi
