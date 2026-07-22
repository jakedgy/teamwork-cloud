#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib.sh"
enable_diagnostics

if [[ -f $STATE_FILE && -z ${NETWORK_MODE+x} && -z ${VPC_ID+x} && -z ${SUBNET_IDS+x} ]]; then
  load_state
fi
AWS_REGION=${AWS_REGION:-us-east-2}
CLUSTER_NAME=${CLUSTER_NAME:-twc-lab}
NETWORK_MODE=${NETWORK_MODE:-managed}
VPC_ID=${VPC_ID:-}
SUBNET_IDS=${SUBNET_IDS:-}
STACK_NAME="${CLUSTER_NAME}-vpc"
FAILED_SERVICE=${FAILED_SERVICE:-}
NLB_HOSTNAME=${NLB_HOSTNAME:-}

AWS_REGION="$AWS_REGION" CLUSTER_NAME="$CLUSTER_NAME" NETWORK_MODE="$NETWORK_MODE" VPC_ID="$VPC_ID" SUBNET_IDS="$SUBNET_IDS" "$SCRIPT_DIR/preflight.sh"
ACCOUNT_ID=$(current_account)

if [[ $NETWORK_MODE == managed ]]; then
  if stack_check=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackStatus' --output text 2>&1); then
    owner_tag=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Tags[?Key=='twc-lab:managed'].Value | [0]" --output text)
    [[ $owner_tag == true ]] || die "Refusing to reuse untagged CloudFormation stack $STACK_NAME"
    log "Reusing managed network stack $STACK_NAME"
  elif [[ $stack_check == *ValidationError* && $stack_check == *"does not exist"* ]]; then
    log "Creating managed network stack $STACK_NAME"
    aws cloudformation deploy \
      --stack-name "$STACK_NAME" \
      --region "$AWS_REGION" \
      --template-file "$SCRIPT_ROOT/cluster/vpc-public.yaml" \
      --parameter-overrides "ClusterName=$CLUSTER_NAME" \
      --tags twc-lab:managed=true \
      --no-fail-on-empty-changeset
  else
    die "Unable to verify whether CloudFormation stack $STACK_NAME exists"
  fi
  VPC_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue | [0]" --output text)
  SUBNET_IDS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetIds'].OutputValue | [0]" --output text)
  [[ $VPC_ID == vpc-* && $SUBNET_IDS == subnet-* ]] || die "Managed stack did not return usable network outputs"
else
  STACK_NAME=
fi

write_state

if [[ ! -f $SECRETS_FILE ]]; then
  ensure_lab_dir
  umask 077
  password=$(openssl rand -hex 16)
  [[ ${#password} == 32 ]] || die "Failed to generate a 32-character Artemis password"
  printf 'secrets:\n  artemisPassword: "%s"\n' "$password" >"$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  unset password
fi
chmod 600 "$SECRETS_FILE"

"$SCRIPT_DIR/render-cluster-config.sh" >/dev/null
if cluster_check=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>&1); then
  log "Reusing tracked EKS cluster $CLUSTER_NAME"
elif [[ $cluster_check == *ResourceNotFoundException* ]]; then
  eksctl create cluster --config-file "$CLUSTER_CONFIG"
else
  die "Unable to verify whether tracked cluster $CLUSTER_NAME exists"
fi
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.13.3 \
  --namespace ingress-nginx \
  --create-namespace \
  --values "$SCRIPT_ROOT/cluster/ingress-nginx-values.yaml" \
  --atomic --timeout 15m

helm upgrade --install twc-lab "$SCRIPT_ROOT/charts/twc-lab" \
  --namespace twc-lab \
  --create-namespace \
  --values "$SECRETS_FILE" \
  --set-string "clusterName=$CLUSTER_NAME" \
  --set-string "awsRegion=$AWS_REGION" \
  --atomic --timeout 15m

kubectl wait --namespace twc-lab --for=condition=Ready pod --all --timeout=15m

deadline=$((SECONDS + ${NLB_WAIT_SECONDS:-900}))
while (( SECONDS < deadline )); do
  NLB_HOSTNAME=$(kubectl get service ingress-nginx-controller --namespace ingress-nginx --output "jsonpath={.status.loadBalancer.ingress[0].hostname}" 2>/dev/null || true)
  [[ -n $NLB_HOSTNAME ]] && break
  sleep "${POLL_SECONDS:-10}"
done
[[ -n $NLB_HOSTNAME ]] || die "Timed out waiting for the ingress NLB hostname"
write_state

printf 'Web app:        http://%s/webapp\n' "$NLB_HOSTNAME"
printf 'Administration: http://%s/admin\n' "$NLB_HOSTNAME"
printf 'License admin:  http://%s/admin/license\n' "$NLB_HOSTNAME"
