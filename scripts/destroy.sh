#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics
configure_timeouts
require_commands aws eksctl helm jq kubectl
load_state
verify_current_account

if [[ $NETWORK_MODE == managed ]]; then
  network_ownership='lab-managed'
else
  network_ownership='externally-owned'
fi
log "Destroy target:"
log "  Account: $ACCOUNT_ID"
log "  Region: $AWS_REGION"
log "  Cluster: $CLUSTER_NAME"
log "  Network mode: $NETWORK_MODE"
log "  VPC: ${VPC_ID:-not created}"
log "  Network ownership: $network_ownership"
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

pv_names=
volume_ids=${PENDING_VOLUME_IDS//,/$'\n'}
if (( cluster_exists == 1 )); then
  if [[ -z $CLUSTER_ARN ]]; then recover_cluster_identity; else verify_cluster_identity; fi
  if phase_requires_kube_cleanup; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG_FILE"
    chmod 600 "$KUBECONFIG_FILE"

    pvc_json=$(lab_kubectl get persistentvolumeclaims --namespace twc-lab --selector 'app.kubernetes.io/instance=twc-lab' --output json)
    pv_names=$(printf '%s' "$pvc_json" | jq -r '.items[]?.spec.volumeName // empty')
    while IFS= read -r pv_name; do
      [[ -n $pv_name ]] || continue
      pv_json=$(lab_kubectl get persistentvolume "$pv_name" --output json)
      volume_id=$(printf '%s' "$pv_json" | jq -r '.spec.csi.volumeHandle // empty')
      [[ -z $volume_id || $volume_id =~ ^vol-[A-Za-z0-9]+$ ]] || die "Persistent volume $pv_name has an invalid EBS volume ID"
      if [[ -n $volume_id ]] && ! grep -Fxq "$volume_id" <<<"$volume_ids"; then
        volume_ids="${volume_ids}${volume_ids:+$'\n'}${volume_id}"
      fi
    done <<<"$pv_names"

    verify_cluster_identity
    workloads_removed=1
    lab_helm uninstall twc-lab --namespace twc-lab --ignore-not-found --wait --timeout 15m >/dev/null 2>&1 || { failed=1; workloads_removed=0; }
    if (( workloads_removed == 1 )); then
      pending_csv=
      while IFS= read -r volume_id; do
        [[ -n $volume_id ]] || continue
        pending_csv="${pending_csv}${pending_csv:+,}${volume_id}"
      done <<<"$volume_ids"
      PENDING_VOLUME_IDS=$pending_csv
      write_state

      verify_cluster_identity
      lab_kubectl delete persistentvolumeclaims --namespace twc-lab --selector 'app.kubernetes.io/instance=twc-lab' --ignore-not-found=true --wait=true --timeout=15m >/dev/null 2>&1 || failed=1

      storage_deadline=$((SECONDS + STORAGE_WAIT_SECONDS))
      while IFS= read -r pv_name; do
        [[ -n $pv_name ]] || continue
        while :; do
          remaining_pv=$(lab_kubectl get persistentvolume "$pv_name" --ignore-not-found=true --output name)
          [[ -z $remaining_pv ]] && break
          (( SECONDS >= storage_deadline )) && { failed=1; break; }
          sleep "$POLL_SECONDS"
        done
      done <<<"$pv_names"
    fi

    verify_cluster_identity
    discovered_hostname=$(lab_kubectl get service ingress-nginx-controller --namespace ingress-nginx --output 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n $discovered_hostname ]]; then NLB_HOSTNAME=$discovered_hostname; write_state; fi
    verify_cluster_identity
    lab_kubectl delete service ingress-nginx-controller --namespace ingress-nginx --ignore-not-found=true >/dev/null 2>&1 || failed=1
    verify_cluster_identity
    lab_helm uninstall ingress-nginx --namespace ingress-nginx --ignore-not-found --wait --timeout 15m >/dev/null 2>&1 || failed=1
  fi
fi

if [[ -n $volume_ids ]]; then
  storage_deadline=$((SECONDS + STORAGE_WAIT_SECONDS))
  volumes_confirmed=1
  while IFS= read -r volume_id; do
    [[ -n $volume_id ]] || continue
    while :; do
      if volume_result=$(aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids "$volume_id" --query 'Volumes[].VolumeId' --output text 2>&1); then
        [[ -z $volume_result || $volume_result == None ]] && break
      elif [[ $volume_result == *InvalidVolume.NotFound* ]]; then
        break
      else
        log "Unable to verify deletion of EBS volume $volume_id"
        failed=1
        volumes_confirmed=0
        break
      fi
      (( SECONDS >= storage_deadline )) && { failed=1; volumes_confirmed=0; break; }
      sleep "$POLL_SECONDS"
    done
  done <<<"$volume_ids"
  if (( volumes_confirmed == 1 )); then
    PENDING_VOLUME_IDS=
    write_state
  fi
fi

if [[ -n $NLB_HOSTNAME ]]; then
  nlb_deadline=$((SECONDS + NLB_WAIT_SECONDS))
  while :; do
    if ! nlb_arns=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[?DNSName=='$NLB_HOSTNAME'].LoadBalancerArn" --output text); then
      log "Unable to confirm deletion of ingress load balancer $NLB_HOSTNAME"; failed=1; break
    fi
    [[ -z $nlb_arns || $nlb_arns == None ]] && break
    (( SECONDS >= nlb_deadline )) && { failed=1; break; }
    sleep "$POLL_SECONDS"
  done
fi

if (( failed == 0 && cluster_exists == 1 )); then
  advance_phase CLUSTER_DELETING
  verify_cluster_identity
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait || failed=1
fi

if (( failed == 0 )); then
  all_elb_arns=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text)
  residual_elbs=
  if [[ -n $all_elb_arns && $all_elb_arns != None ]]; then
    read -r -a elb_arns <<<"$all_elb_arns"
    for elb_arn in "${elb_arns[@]}"; do
      tagged_arn=$(aws elbv2 describe-tags --region "$AWS_REGION" --resource-arns "$elb_arn" --query "TagDescriptions[?Tags[?Key=='eks:eks-cluster-name' && Value=='$CLUSTER_NAME']].ResourceArn" --output text)
      [[ -z $tagged_arn || $tagged_arn == None ]] || residual_elbs="${residual_elbs}${residual_elbs:+,}${tagged_arn}"
    done
  fi
  residual_volumes=$(aws ec2 describe-volumes --region "$AWS_REGION" --filters "Name=tag:eks:eks-cluster-name,Values=$CLUSTER_NAME" --query 'Volumes[].VolumeId' --output text)
  [[ -z $residual_elbs || $residual_elbs == None ]] || { log "Residual load balancers: $residual_elbs"; failed=1; }
  [[ -z $residual_volumes || $residual_volumes == None ]] || { log "Residual EBS volumes: $residual_volumes"; failed=1; }
fi

if (( failed == 0 )) && [[ $NETWORK_MODE == managed ]]; then
  if stack_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackStatus' --output text 2>&1); then
    if [[ -z $VPC_STACK_ID ]]; then recover_stack_identity; else verify_stack_identity; fi
    if [[ $stack_status != DELETE_IN_PROGRESS ]]; then
      aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
    fi
    if ! aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then failed=1; fi
  elif [[ $stack_status == *ValidationError* && $stack_status == *"does not exist"* ]]; then
    log "Managed stack is already absent"
  else
    die "Unable to verify whether managed stack $STACK_NAME exists"
  fi
fi

(( failed == 0 )) || die "Cleanup was incomplete; state remains at $STATE_FILE"
rm -f -- "$STATE_FILE" "$CLUSTER_CONFIG" "$SECRETS_FILE" "$KUBECONFIG_FILE"
log "Cluster cleanup complete"
