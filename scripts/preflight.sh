#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
enable_diagnostics

AWS_REGION=${AWS_REGION:-us-east-2}
CLUSTER_NAME=${CLUSTER_NAME:-twc-lab}
NETWORK_MODE=${NETWORK_MODE:-managed}
VPC_ID=${VPC_ID:-}
PUBLIC_SUBNET_IDS=${PUBLIC_SUBNET_IDS:-}
SUBNET_IDS=${SUBNET_IDS:-}
resolve_public_subnet_ids

# These checks intentionally precede any external command, especially AWS.
validate_network_mode "$NETWORK_MODE"
validate_region "$AWS_REGION"
validate_cluster_name "$CLUSTER_NAME"
if [[ $NETWORK_MODE == managed ]]; then validate_stack_name "${CLUSTER_NAME}-vpc"; fi
if [[ $NETWORK_MODE == existing ]]; then
  [[ -n $VPC_ID ]] || die "VPC_ID is required in existing mode"
  [[ $VPC_ID =~ ^vpc-[A-Za-z0-9]+$ ]] || die "Invalid VPC_ID"
  [[ -n $PUBLIC_SUBNET_IDS ]] || die "PUBLIC_SUBNET_IDS is required in existing mode"
  split_csv "$PUBLIC_SUBNET_IDS"
  (( ${#CSV_VALUES[@]} >= 2 )) || die "At least two public subnet IDs are required"
fi

require_commands aws eksctl jq kubectl helm make openssl

caller_account=$(current_account)
validate_account_id "$caller_account"
ACCOUNT_ID=$caller_account

state_present=0
if [[ -f $STATE_FILE ]]; then
  state_present=1
  requested_region=$AWS_REGION requested_cluster=$CLUSTER_NAME requested_mode=$NETWORK_MODE
  load_state
  [[ $ACCOUNT_ID == "$caller_account" ]] || die "Existing state belongs to AWS account $ACCOUNT_ID, caller is $caller_account"
  [[ $AWS_REGION == "$requested_region" ]] || die "Existing state belongs to region $AWS_REGION"
  [[ $CLUSTER_NAME == "$requested_cluster" ]] || die "Existing state belongs to cluster $CLUSTER_NAME"
  [[ $NETWORK_MODE == "$requested_mode" ]] || die "Existing state uses network mode $NETWORK_MODE"
else
  if cluster_check=$(trap - ERR; aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>&1); then
    die "Cluster $CLUSTER_NAME already exists but is not tracked by $STATE_FILE"
  elif [[ $cluster_check != *ResourceNotFoundException* ]]; then
    die "Unable to verify whether cluster $CLUSTER_NAME already exists"
  fi
fi

if [[ $NETWORK_MODE == managed ]]; then
  intended_stack="${CLUSTER_NAME}-vpc"
  if stack_check=$(trap - ERR; aws cloudformation describe-stacks --stack-name "$intended_stack" --region "$AWS_REGION" --query 'Stacks[0].StackStatus' --output text 2>&1); then
    (( state_present == 1 )) || die "Stack $intended_stack exists without tracked deployment state"
    if [[ -z $VPC_STACK_ID ]]; then recover_stack_identity; else verify_stack_identity; fi
  elif [[ $stack_check != *ValidationError* || $stack_check != *"does not exist"* ]]; then
    die "Unable to verify whether CloudFormation stack $intended_stack exists"
  elif (( state_present == 1 )) && [[ -n $VPC_STACK_ID ]]; then
    die "Tracked stack $VPC_STACK_ID is missing; run destroy for scoped recovery"
  fi
fi

if [[ $NETWORK_MODE == existing ]]; then
  vpcs=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" --query 'Vpcs[].VpcId' --output text)
  read -r -a found_vpcs <<<"$vpcs"
  if (( ${#found_vpcs[@]} != 1 )) || [[ ${found_vpcs[0]} != "$VPC_ID" ]]; then
    die "VPC_ID must resolve to exactly one VPC"
  fi

  split_csv "$PUBLIC_SUBNET_IDS"
  rows=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "${CSV_VALUES[@]}" --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].join(\`\\t\`,[SubnetId,AvailabilityZone,to_string(AvailableIpAddressCount),to_string(MapPublicIpOnLaunch),not_null(Tags[?Key=='kubernetes.io/role/elb']|[0].Value, \`None\`)])" --output text)
  requested_count=${#CSV_VALUES[@]}
  seen_count=0
  seen_csv=,
  az_csv=,
  az_count=0
  for subnet in "${CSV_VALUES[@]}"; do
    [[ $subnet =~ ^subnet-[A-Za-z0-9]+$ ]] || die "Invalid subnet ID: $subnet"
    [[ $seen_csv != *",$subnet,"* ]] || die "Duplicate subnet ID: $subnet"
    seen_csv="${seen_csv}${subnet},"
  done
  seen_csv=,
  while IFS=$'\t' read -r subnet az free_ips public_ip elb_role; do
    [[ -n ${subnet:-} ]] || continue
    requested_subnet=0
    for requested_id in "${CSV_VALUES[@]}"; do
      [[ $subnet == "$requested_id" ]] && requested_subnet=1
    done
    (( requested_subnet == 1 )) || die "AWS returned an unexpected subnet: $subnet"
    [[ $seen_csv != *",$subnet,"* ]] || die "AWS returned subnet $subnet more than once"
    if [[ ! $free_ips =~ ^[0-9]+$ ]] || (( free_ips < 16 )); then
      die "Subnet $subnet has fewer than 16 available IP addresses"
    fi
    case "$public_ip" in
      True|true) ;;
      *) die "Subnet $subnet does not map public IPs on launch" ;;
    esac
    [[ $elb_role == 1 ]] || die "Subnet $subnet is missing kubernetes.io/role/elb=1"
    seen_csv="${seen_csv}${subnet},"
    seen_count=$((seen_count + 1))
    if [[ $az_csv != *",$az,"* ]]; then
      az_csv="${az_csv}${az},"
      az_count=$((az_count + 1))
    fi
  done <<<"$rows"
  (( seen_count == requested_count )) || die "Not all requested subnets exist in VPC $VPC_ID"
  (( az_count >= 2 )) || die "Existing subnets must span at least two availability zones"

  for subnet in "${CSV_VALUES[@]}"; do
    route_table_id=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.subnet-id,Values=$subnet" --query 'RouteTables[0].RouteTableId' --output text)
    if [[ -z $route_table_id || $route_table_id == None ]]; then
      route_table_id=$(aws ec2 describe-route-tables --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" 'Name=association.main,Values=true' --query 'RouteTables[0].RouteTableId' --output text)
    fi
    [[ -n $route_table_id && $route_table_id != None ]] || die "Subnet $subnet has no effective route table"
    default_route=$(aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$route_table_id" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active' && starts_with(GatewayId, 'igw-')].GatewayId | [0]" --output text)
    [[ -n $default_route && $default_route == igw-* ]] || die "Subnet $subnet has no active 0.0.0.0/0 route through an internet gateway"
  done
fi

log "Preflight passed for account $ACCOUNT_ID, region $AWS_REGION, cluster $CLUSTER_NAME ($NETWORK_MODE network)"
