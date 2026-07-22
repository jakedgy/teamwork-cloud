#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib.sh"
enable_diagnostics
configure_timeouts

had_state=0
requested_region_set=${AWS_REGION+x}; requested_region=${AWS_REGION:-}
requested_cluster_set=${CLUSTER_NAME+x}; requested_cluster=${CLUSTER_NAME:-}
requested_mode_set=${NETWORK_MODE+x}; requested_mode=${NETWORK_MODE:-}
requested_vpc_set=${VPC_ID+x}; requested_vpc=${VPC_ID:-}
requested_subnets_set=${SUBNET_IDS+x}; requested_subnets=${SUBNET_IDS:-}
if [[ -f $STATE_FILE ]]; then
  load_state
  had_state=1
  [[ -z $requested_region_set || $requested_region == "$AWS_REGION" ]] || die "AWS_REGION conflicts with tracked state"
  [[ -z $requested_cluster_set || $requested_cluster == "$CLUSTER_NAME" ]] || die "CLUSTER_NAME conflicts with tracked state"
  [[ -z $requested_mode_set || $requested_mode == "$NETWORK_MODE" ]] || die "NETWORK_MODE conflicts with tracked state"
  [[ -z $requested_vpc_set || $requested_vpc == "$VPC_ID" ]] || die "VPC_ID conflicts with tracked state"
  [[ -z $requested_subnets_set || $requested_subnets == "$SUBNET_IDS" ]] || die "SUBNET_IDS conflicts with tracked state"
fi
AWS_REGION=${AWS_REGION:-us-east-2}
CLUSTER_NAME=${CLUSTER_NAME:-twc-lab}
NETWORK_MODE=${NETWORK_MODE:-managed}
VPC_ID=${VPC_ID:-}
SUBNET_IDS=${SUBNET_IDS:-}
STACK_NAME="${CLUSTER_NAME}-vpc"
DEPLOYMENT_ID=${DEPLOYMENT_ID:-}
CLUSTER_ARN=${CLUSTER_ARN:-}
VPC_STACK_ID=${VPC_STACK_ID:-}
FAILED_SERVICE=${FAILED_SERVICE:-}
NLB_HOSTNAME=${NLB_HOSTNAME:-}

AWS_REGION="$AWS_REGION" CLUSTER_NAME="$CLUSTER_NAME" NETWORK_MODE="$NETWORK_MODE" VPC_ID="$VPC_ID" SUBNET_IDS="$SUBNET_IDS" "$SCRIPT_DIR/preflight.sh"
ACCOUNT_ID=$(current_account)

if (( had_state == 0 )); then
  DEPLOYMENT_ID=$(openssl rand -hex 16)
  [[ $DEPLOYMENT_ID =~ ^[a-f0-9]{32}$ ]] || die "Failed to generate deployment identity"
  write_state
fi

if [[ $NETWORK_MODE == managed ]]; then
  if stack_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackStatus' --output text 2>&1); then
    verify_stack_identity
    case "$stack_status" in
      CREATE_COMPLETE|UPDATE_COMPLETE) log "Reusing identity-verified network stack $VPC_STACK_ID" ;;
      *) die "Stack $VPC_STACK_ID is $stack_status; preserve state and run destroy for scoped recovery" ;;
    esac
  elif [[ $stack_status == *ValidationError* && $stack_status == *"does not exist"* ]]; then
    [[ -z $VPC_STACK_ID ]] || die "Tracked stack $VPC_STACK_ID is absent; run destroy to clear scoped state"
    log "Creating managed network stack $STACK_NAME"
    if ! aws cloudformation deploy \
      --stack-name "$STACK_NAME" \
      --region "$AWS_REGION" \
      --template-file "$SCRIPT_ROOT/cluster/vpc-public.yaml" \
      --parameter-overrides "ClusterName=$CLUSTER_NAME" "DeploymentId=$DEPLOYMENT_ID" \
      --tags twc-lab:managed=true "twc-lab:deployment-id=$DEPLOYMENT_ID" \
      --no-fail-on-empty-changeset; then
      if partial_stack_id=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackId' --output text); then
        VPC_STACK_ID=$partial_stack_id
        validate_stack_id "$VPC_STACK_ID"
        write_state
      fi
      die "CloudFormation deployment failed; scoped identity state was preserved"
    fi
    VPC_STACK_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackId' --output text)
    validate_stack_id "$VPC_STACK_ID"
    write_state
  else
    die "Unable to verify whether CloudFormation stack $STACK_NAME exists"
  fi
  VPC_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue | [0]" --output text)
  SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetIds'].OutputValue | [0]" --output text)
  [[ $VPC_ID == vpc-* && $SUBNET_IDS == subnet-* ]] || die "Managed stack has no usable outputs; state is preserved for scoped destroy"
else
  STACK_NAME=
  VPC_STACK_ID=
fi
write_state

if [[ ! -f $SECRETS_FILE ]]; then
  ensure_lab_dir
  umask 077
  password=$(openssl rand -hex 16)
  [[ ${#password} == 32 ]] || die "Failed to generate a 32-character Artemis password"
  printf 'secrets:\n  artemisPassword: "%s"\n' "$password" >"$SECRETS_FILE"
  unset password
fi
chmod 600 "$SECRETS_FILE"

"$SCRIPT_DIR/render-cluster-config.sh" >/dev/null
if cluster_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>&1); then
  if [[ -z $CLUSTER_ARN ]]; then recover_cluster_identity; else verify_cluster_identity; fi
  log "Reusing identity-verified EKS cluster $CLUSTER_ARN"
elif [[ $cluster_status == *ResourceNotFoundException* ]]; then
  [[ -z $CLUSTER_ARN ]] || die "Tracked cluster $CLUSTER_ARN is absent; refusing same-name recreation"
  create_failed=0
  eksctl create cluster --config-file "$CLUSTER_CONFIG" || create_failed=1
  if live_cluster=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.arn' --output text 2>&1); then
    recover_cluster_identity
  elif (( create_failed == 1 )); then
    die "eksctl failed and no deployment-owned cluster could be recovered; state is preserved"
  else
    die "eksctl returned success but the cluster ARN could not be verified"
  fi
  (( create_failed == 0 )) || die "eksctl failed after creating deployment-owned cluster $CLUSTER_ARN; state is preserved for retry or destroy"
else
  die "Unable to verify whether tracked cluster $CLUSTER_NAME exists"
fi

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"

lab_helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
lab_helm repo update ingress-nginx
verify_cluster_identity
lab_helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.13.3 --namespace ingress-nginx --create-namespace \
  --values "$SCRIPT_ROOT/cluster/ingress-nginx-values.yaml" --atomic --timeout 15m

verify_cluster_identity
lab_helm upgrade --install twc-lab "$SCRIPT_ROOT/charts/twc-lab" \
  --namespace twc-lab --create-namespace --values "$SECRETS_FILE" \
  --set-string "clusterName=$CLUSTER_NAME" --set-string "awsRegion=$AWS_REGION" \
  --atomic --timeout 15m

verify_cluster_identity
lab_kubectl wait --namespace twc-lab --for=condition=Ready pod --all --timeout=15m

deadline=$((SECONDS + NLB_WAIT_SECONDS))
NLB_HOSTNAME=
while :; do
  NLB_HOSTNAME=$(lab_kubectl get service ingress-nginx-controller --namespace ingress-nginx --output "jsonpath={.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
  [[ -n $NLB_HOSTNAME ]] && break
  (( SECONDS >= deadline )) && break
  sleep "$POLL_SECONDS"
done
[[ -n $NLB_HOSTNAME ]] || die "Timed out waiting for the ingress NLB hostname"
write_state

printf 'Web app:        http://%s/webapp\n' "$NLB_HOSTNAME"
printf 'Administration: http://%s/admin\n' "$NLB_HOSTNAME"
printf 'License admin:  http://%s/admin/license\n' "$NLB_HOSTNAME"
