#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics
require_commands aws eksctl kubectl helm
load_state
verify_current_account
confirm_action "destroy cluster $CLUSTER_NAME" "$CLUSTER_NAME"

failed=0
cluster_exists=0
cluster_error="$LAB_DIR/.cluster-check.$$"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text >/dev/null 2>"$cluster_error"; then
  cluster_exists=1
elif ! grep -q 'ResourceNotFoundException' "$cluster_error"; then
  rm -f -- "$cluster_error"
  die "Unable to verify whether EKS cluster $CLUSTER_NAME exists"
fi
rm -f -- "$cluster_error"

if (( cluster_exists == 1 )); then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
  helm uninstall twc-lab --namespace twc-lab --ignore-not-found --wait --timeout 15m >/dev/null 2>&1 || failed=1
  kubectl delete service ingress-nginx-controller --namespace ingress-nginx --ignore-not-found=true >/dev/null 2>&1 || failed=1
  helm uninstall ingress-nginx --namespace ingress-nginx --ignore-not-found --wait --timeout 15m >/dev/null 2>&1 || failed=1
fi

if [[ -n $NLB_HOSTNAME ]]; then
  nlb_deadline=$((SECONDS + ${NLB_WAIT_SECONDS:-900}))
  while (( SECONDS < nlb_deadline )); do
    nlb_arns=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?DNSName=='$NLB_HOSTNAME'].LoadBalancerArn" --output text 2>/dev/null || true)
    [[ -z $nlb_arns || $nlb_arns == None ]] && break
    sleep "${POLL_SECONDS:-10}"
  done
  [[ -z ${nlb_arns:-} || ${nlb_arns:-} == None ]] || failed=1
fi

if (( failed == 0 && cluster_exists == 1 )); then
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait || failed=1
fi

if (( failed == 0 )); then
  residual_elbs=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" --resource-type-filters elasticloadbalancing:loadbalancer --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" --query 'ResourceTagMappingList[].ResourceARN' --output text)
  residual_volumes=$(aws ec2 describe-volumes --region "$AWS_REGION" --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned,shared" --query 'Volumes[].VolumeId' --output text)
  [[ -z $residual_elbs || $residual_elbs == None ]] || { log "Residual load balancers: $residual_elbs"; failed=1; }
  [[ -z $residual_volumes || $residual_volumes == None ]] || { log "Residual EBS volumes: $residual_volumes"; failed=1; }
fi

if (( failed == 0 )) && [[ $NETWORK_MODE == managed ]]; then
  [[ -n $STACK_NAME ]] || die "Managed state has no stack name"
  owner_tag=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Tags[?Key=='twc-lab:managed'].Value | [0]" --output text)
  [[ $owner_tag == true ]] || die "Refusing to delete untagged stack $STACK_NAME"
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION" || failed=1
  if (( failed == 0 )); then
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION" || failed=1
  fi
fi

if (( failed != 0 )); then
  die "Cleanup was incomplete; state remains at $STATE_FILE"
fi

rm -f -- "$STATE_FILE" "$CLUSTER_CONFIG" "$SECRETS_FILE"
log "Cluster cleanup complete"
