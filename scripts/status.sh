#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics
require_commands aws helm jq kubectl
load_state
verify_current_account

if cluster_lookup=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>&1); then
  cluster_status=$cluster_lookup
  verify_cluster_identity
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"
elif [[ $cluster_lookup == *ResourceNotFoundException* ]]; then
  cluster_status=NOT_FOUND
else
  cluster_status=UNKNOWN
  log "Unable to query EKS cluster status"
fi
helm_releases=$(lab_helm list --all-namespaces --filter '^(twc-lab|ingress-nginx)$' --output json 2>/dev/null || printf '[]')
pods=$(lab_kubectl get pods --namespace twc-lab --output name 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
pvcs=$(lab_kubectl get persistentvolumeclaims --namespace twc-lab --output name 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
ingress_hostname=$(lab_kubectl get service ingress-nginx-controller --namespace ingress-nginx --output 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
simulator_health=$(lab_kubectl get --raw '/api/v1/namespaces/twc-lab/services/http:twc-lab-simulator:8080/proxy/api/health' 2>/dev/null || printf 'unavailable')
layer_explanation='ingress -> simulator -> backing services -> PVC storage'

if [[ ${JSON:-0} == 1 ]]; then
  printf '%s' "$helm_releases" | jq -c \
    --arg account "$ACCOUNT_ID" --arg region "$AWS_REGION" --arg cluster "$CLUSTER_NAME" \
    --arg clusterStatus "$cluster_status" --arg phase "$PHASE" --arg networkMode "$NETWORK_MODE" --arg vpc "$VPC_ID" \
    --arg publicSubnetIds "$PUBLIC_SUBNET_IDS" --arg pods "$pods" --arg pvcs "$pvcs" \
    --arg ingressHostname "$ingress_hostname" --arg simulatorHealth "$simulator_health" \
    --arg failedService "$FAILED_SERVICE" --arg pendingVolumeIds "$PENDING_VOLUME_IDS" --arg layerExplanation "$layer_explanation" \
    '{account:$account,region:$region,cluster:$cluster,clusterStatus:$clusterStatus,phase:$phase,networkMode:$networkMode,vpc:$vpc,publicSubnetIds:$publicSubnetIds,helmReleases:.,pods:$pods,pvcs:$pvcs,ingressHostname:$ingressHostname,simulatorHealth:$simulatorHealth,failedService:$failedService,pendingVolumeIds:$pendingVolumeIds,layerExplanation:$layerExplanation}'
else
  printf 'Account:        %s\n' "$ACCOUNT_ID"
  printf 'Region:         %s\n' "$AWS_REGION"
  printf 'Cluster:        %s (%s)\n' "$CLUSTER_NAME" "$cluster_status"
  printf 'Phase:          %s\n' "$PHASE"
  printf 'Network:        %s (%s)\n' "$NETWORK_MODE" "$VPC_ID"
  printf 'Public subnets: %s\n' "$PUBLIC_SUBNET_IDS"
  printf 'Helm releases:  %s\n' "$helm_releases"
  printf 'Pods:           %s\n' "${pods:-none}"
  printf 'PVCs:           %s\n' "${pvcs:-none}"
  printf 'Ingress:        %s\n' "${ingress_hostname:-pending}"
  printf 'Simulator health: %s\n' "$simulator_health"
  printf 'Failed service: %s\n' "${FAILED_SERVICE:-none}"
  printf 'Pending volumes: %s\n' "${PENDING_VOLUME_IDS:-none}"
  printf 'Layers:         %s\n' "$layer_explanation"
  printf 'URL:            http://%s/webapp\n' "${ingress_hostname:-pending}"
fi
