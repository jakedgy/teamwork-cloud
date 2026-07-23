#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034 # Used by scripts that source this lifecycle library.
readonly SCRIPT_ROOT
readonly LAB_DIR="$PWD/.twc-lab"
readonly STATE_FILE="$LAB_DIR/state.env"
# shellcheck disable=SC2034 # Used by scripts that source this lifecycle library.
readonly CLUSTER_CONFIG="$LAB_DIR/cluster.yaml"
# shellcheck disable=SC2034 # Used by scripts that source this lifecycle library.
readonly SECRETS_FILE="$LAB_DIR/secrets.yaml"
readonly KUBECONFIG_FILE="$LAB_DIR/kubeconfig"

log() { printf '[twc-lab] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

on_error() {
  local status=$1 line=$2
  log "Command failed at line $line (exit $status). State was retained for diagnosis."
}

enable_diagnostics() {
  trap 'on_error "$?" "$LINENO"' ERR
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
  done
}

validate_network_mode() {
  case "$1" in
    managed|existing) ;;
    *) die "NETWORK_MODE must be 'managed' or 'existing' (got '$1')" ;;
  esac
}

validate_simple_name() {
  local label=$1 value=$2
  [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || die "$label contains invalid characters"
}

validate_cluster_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || die "CLUSTER_NAME is not a valid EKS cluster name"
}

validate_stack_name() {
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9-]{0,127}$ ]] || die "Derived CloudFormation stack name is invalid"
}

validate_region() {
  [[ $1 =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || die "Invalid AWS region: $1"
}

validate_account_id() {
  [[ $1 =~ ^[0-9]{12}$ ]] || die "Invalid AWS account ID returned by AWS"
}

ensure_lab_dir() {
  mkdir -p "$LAB_DIR"
  chmod 700 "$LAB_DIR"
}

load_state() {
  [[ -f $STATE_FILE ]] || die "State file not found: $STATE_FILE"
  local key value
  ACCOUNT_ID='' AWS_REGION='' CLUSTER_NAME='' NETWORK_MODE='' PHASE='' DEPLOYMENT_ID='' CLUSTER_ARN=''
  VPC_ID='' PUBLIC_SUBNET_IDS='' SUBNET_IDS='' STACK_NAME='' VPC_STACK_ID='' PENDING_VOLUME_IDS=''
  SIMULATOR_IMAGE_REPOSITORY='' SIMULATOR_IMAGE_TAG='' FAILED_SERVICE='' NLB_HOSTNAME=''
  while IFS='=' read -r key value || [[ -n ${key:-} ]]; do
    [[ -n ${key:-} ]] || continue
    case "$key" in
      ACCOUNT_ID|AWS_REGION|CLUSTER_NAME|NETWORK_MODE|PHASE|DEPLOYMENT_ID|CLUSTER_ARN|VPC_ID|PUBLIC_SUBNET_IDS|SUBNET_IDS|STACK_NAME|VPC_STACK_ID|PENDING_VOLUME_IDS|SIMULATOR_IMAGE_REPOSITORY|SIMULATOR_IMAGE_TAG|FAILED_SERVICE|NLB_HOSTNAME)
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "Invalid newline in state value"
        printf -v "$key" '%s' "$value"
        ;;
      *) die "Unknown key '$key' in state file" ;;
    esac
  done <"$STATE_FILE"
  [[ -n $ACCOUNT_ID && -n $AWS_REGION && -n $CLUSTER_NAME && -n $NETWORK_MODE ]] || die "State file is incomplete"
  validate_account_id "$ACCOUNT_ID"
  validate_region "$AWS_REGION"
  validate_cluster_name "$CLUSTER_NAME"
  validate_network_mode "$NETWORK_MODE"
  validate_phase "$PHASE"
  resolve_public_subnet_ids
  validate_simulator_image_override "$SIMULATOR_IMAGE_REPOSITORY" "$SIMULATOR_IMAGE_TAG"
  [[ $DEPLOYMENT_ID =~ ^[a-f0-9]{32}$ ]] || die "State contains an invalid deployment ID"
  [[ -z $CLUSTER_ARN ]] || validate_cluster_arn "$CLUSTER_ARN"
  [[ -z $VPC_STACK_ID ]] || validate_stack_id "$VPC_STACK_ID"
  if [[ -n $PENDING_VOLUME_IDS ]]; then
    split_csv "$PENDING_VOLUME_IDS"
    local volume seen_volumes=,
    for volume in "${CSV_VALUES[@]}"; do
      [[ $volume =~ ^vol-[A-Za-z0-9]+$ ]] || die "State contains an invalid pending volume ID"
      [[ $seen_volumes != *",$volume,"* ]] || die "State contains a duplicate pending volume ID"
      seen_volumes="${seen_volumes}${volume},"
    done
  fi
  if [[ -n $VPC_ID ]]; then
    [[ $VPC_ID =~ ^vpc-[A-Za-z0-9]+$ ]] || die "State contains an invalid VPC ID"
  fi
  if [[ -n $PUBLIC_SUBNET_IDS ]]; then
    split_csv "$PUBLIC_SUBNET_IDS"
    (( ${#CSV_VALUES[@]} >= 2 )) || die "State must contain at least two subnet IDs"
    local subnet
    for subnet in "${CSV_VALUES[@]}"; do
      [[ $subnet =~ ^subnet-[A-Za-z0-9]+$ ]] || die "State contains an invalid subnet ID"
    done
  fi
  if [[ $NETWORK_MODE == existing ]]; then
    [[ -n $VPC_ID && -n $PUBLIC_SUBNET_IDS ]] || die "Existing-network state is incomplete"
  fi
  case "$FAILED_SERVICE" in
    ''|cassandra|zookeeper|artemis) ;;
    *) die "State contains an invalid failed service" ;;
  esac
  [[ -z $NLB_HOSTNAME || $NLB_HOSTNAME =~ ^[A-Za-z0-9.-]+$ ]] || die "State contains an invalid NLB hostname"
  if [[ $NETWORK_MODE == managed ]]; then
    [[ $STACK_NAME == "${CLUSTER_NAME}-vpc" ]] || die "Managed stack is outside the cluster's scope"
    validate_stack_name "$STACK_NAME"
  fi
}

write_state() {
  ensure_lab_dir
  local tmp="$LAB_DIR/.state.env.tmp.$$"
  umask 077
  {
    printf 'ACCOUNT_ID=%s\n' "$ACCOUNT_ID"
    printf 'AWS_REGION=%s\n' "$AWS_REGION"
    printf 'CLUSTER_NAME=%s\n' "$CLUSTER_NAME"
    printf 'NETWORK_MODE=%s\n' "$NETWORK_MODE"
    printf 'PHASE=%s\n' "$PHASE"
    printf 'DEPLOYMENT_ID=%s\n' "$DEPLOYMENT_ID"
    printf 'CLUSTER_ARN=%s\n' "${CLUSTER_ARN:-}"
    printf 'VPC_ID=%s\n' "${VPC_ID:-}"
    printf 'PUBLIC_SUBNET_IDS=%s\n' "${PUBLIC_SUBNET_IDS:-}"
    printf 'STACK_NAME=%s\n' "${STACK_NAME:-}"
    printf 'VPC_STACK_ID=%s\n' "${VPC_STACK_ID:-}"
    printf 'PENDING_VOLUME_IDS=%s\n' "${PENDING_VOLUME_IDS:-}"
    printf 'SIMULATOR_IMAGE_REPOSITORY=%s\n' "${SIMULATOR_IMAGE_REPOSITORY:-}"
    printf 'SIMULATOR_IMAGE_TAG=%s\n' "${SIMULATOR_IMAGE_TAG:-}"
    printf 'FAILED_SERVICE=%s\n' "${FAILED_SERVICE:-}"
    printf 'NLB_HOSTNAME=%s\n' "${NLB_HOSTNAME:-}"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

validate_phase() {
  case "$1" in
    INITIALIZED|NETWORK_READY|CLUSTER_CREATING|CLUSTER_READY|HELM_STARTED|DEPLOYED|CLUSTER_DELETING) ;;
    *) die "State contains an invalid lifecycle phase" ;;
  esac
}

phase_rank() {
  case "$1" in
    INITIALIZED) printf '0\n' ;;
    NETWORK_READY) printf '1\n' ;;
    CLUSTER_CREATING) printf '2\n' ;;
    CLUSTER_READY) printf '3\n' ;;
    HELM_STARTED) printf '4\n' ;;
    DEPLOYED) printf '5\n' ;;
    CLUSTER_DELETING) printf '6\n' ;;
    *) die "Unknown lifecycle phase: $1" ;;
  esac
}

advance_phase() {
  local target=$1 current_rank target_rank
  validate_phase "$target"
  current_rank=$(phase_rank "$PHASE")
  target_rank=$(phase_rank "$target")
  if (( target_rank > current_rank )); then
    PHASE=$target
    write_state
  fi
}

phase_requires_kube_cleanup() {
  case "$PHASE" in
    HELM_STARTED|DEPLOYED) return 0 ;;
    INITIALIZED|NETWORK_READY|CLUSTER_CREATING|CLUSTER_READY|CLUSTER_DELETING) return 1 ;;
    *) die "Unknown lifecycle phase: $PHASE" ;;
  esac
}

resolve_public_subnet_ids() {
  PUBLIC_SUBNET_IDS=${PUBLIC_SUBNET_IDS:-}
  SUBNET_IDS=${SUBNET_IDS:-}
  if [[ -n $PUBLIC_SUBNET_IDS && -n $SUBNET_IDS && $PUBLIC_SUBNET_IDS != "$SUBNET_IDS" ]]; then
    die "PUBLIC_SUBNET_IDS conflicts with legacy SUBNET_IDS"
  fi
  PUBLIC_SUBNET_IDS=${PUBLIC_SUBNET_IDS:-$SUBNET_IDS}
}

validate_simulator_image_override() {
  local repository=$1 tag=$2
  if [[ -z $repository && -z $tag ]]; then return 0; fi
  [[ -n $repository && -n $tag ]] || die "SIMULATOR_IMAGE_REPOSITORY and SIMULATOR_IMAGE_TAG must be set together"
  [[ $repository =~ ^ghcr\.io/[a-z0-9]+([._-][a-z0-9]+)*/[a-z0-9]+([._-][a-z0-9]+)*$ ]] || die "Invalid SIMULATOR_IMAGE_REPOSITORY"
  if (( ${#tag} > 128 )) || [[ ! $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    die "Invalid SIMULATOR_IMAGE_TAG"
  fi
}

validate_cluster_arn() {
  [[ $1 =~ ^arn:aws[a-zA-Z-]*:eks:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid EKS cluster ARN"
}

validate_stack_id() {
  [[ $1 =~ ^arn:aws[a-zA-Z-]*:cloudformation:[a-z0-9-]+:[0-9]{12}:stack/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9-]+$ ]] || die "Invalid CloudFormation stack ID"
}

validate_positive_bounded() {
  local label=$1 value=$2 maximum=$3
  if [[ ! $value =~ ^[0-9]+$ ]] || (( value <= 0 || value > maximum )); then
    die "$label must be an integer from 1 to $maximum"
  fi
}

configure_timeouts() {
  NLB_WAIT_SECONDS=${NLB_WAIT_SECONDS:-900}
  STORAGE_WAIT_SECONDS=${STORAGE_WAIT_SECONDS:-900}
  STACK_WAIT_SECONDS=${STACK_WAIT_SECONDS:-3600}
  STACK_DEPENDENCY_GRACE_SECONDS=${STACK_DEPENDENCY_GRACE_SECONDS:-60}
  POLL_SECONDS=${POLL_SECONDS:-10}
  validate_positive_bounded NLB_WAIT_SECONDS "$NLB_WAIT_SECONDS" 3600
  validate_positive_bounded STORAGE_WAIT_SECONDS "$STORAGE_WAIT_SECONDS" 3600
  validate_positive_bounded STACK_WAIT_SECONDS "$STACK_WAIT_SECONDS" 3600
  validate_positive_bounded STACK_DEPENDENCY_GRACE_SECONDS "$STACK_DEPENDENCY_GRACE_SECONDS" 900
  validate_positive_bounded POLL_SECONDS "$POLL_SECONDS" 60
  (( STACK_DEPENDENCY_GRACE_SECONDS < STACK_WAIT_SECONDS )) ||
    die "STACK_DEPENDENCY_GRACE_SECONDS must be less than STACK_WAIT_SECONDS"
}

lab_kubectl() { KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
lab_helm() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }

remediate_guardduty_vpc_dependencies() {
  local endpoint_json matching_endpoints endpoint_count endpoint_id endpoint_state failed_endpoint_ids
  local security_group_json matching_groups group_count group_id delete_error
  local service_name="com.amazonaws.${AWS_REGION}.guardduty-data"
  local group_name="GuardDutyManagedSecurityGroup-${VPC_ID}"
  local group_description="Associated with VPC-${VPC_ID} and tagged as GuardDutyManaged"

  if ! endpoint_json=$(aws ec2 describe-vpc-endpoints \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --output json); then
    log "Unable to inspect VPC endpoints while stack deletion is stalled"
    return 1
  fi
  if ! matching_endpoints=$(printf '%s' "$endpoint_json" | jq -c \
    --arg service "$service_name" \
    '[.VpcEndpoints[]? | select(
      .VpcEndpointType == "Interface" and
      .ServiceName == $service and
      .RequesterManaged == false and
      any(.Tags[]?; .Key == "GuardDutyManaged" and .Value == "true")
    )]'); then
    log "Unable to parse VPC endpoint inventory while stack deletion is stalled"
    return 1
  fi
  endpoint_count=$(printf '%s' "$matching_endpoints" | jq -r 'length')
  if (( endpoint_count > 1 )); then
    log "Refusing automatic cleanup: found $endpoint_count matching GuardDuty endpoints in VPC $VPC_ID"
    return 1
  fi
  if (( endpoint_count == 1 )); then
    endpoint_id=$(printf '%s' "$matching_endpoints" | jq -r '.[0].VpcEndpointId')
    endpoint_state=$(printf '%s' "$matching_endpoints" | jq -r '.[0].State')
    [[ $endpoint_id =~ ^vpce-[A-Za-z0-9]+$ ]] || {
      log "Refusing automatic cleanup: GuardDuty endpoint returned an invalid ID"
      return 1
    }
    if [[ $endpoint_state == deleting ]]; then
      return 0
    fi
    [[ $endpoint_state == available ]] || {
      log "Refusing automatic cleanup: GuardDuty endpoint $endpoint_id is in unexpected state $endpoint_state"
      return 1
    }
    log "Deleting orphaned GuardDuty endpoint $endpoint_id from managed VPC $VPC_ID"
    if ! failed_endpoint_ids=$(aws ec2 delete-vpc-endpoints \
      --region "$AWS_REGION" \
      --vpc-endpoint-ids "$endpoint_id" \
      --query 'Unsuccessful[].VpcEndpointId' \
      --output text); then
      log "Unable to delete orphaned GuardDuty endpoint $endpoint_id"
      return 1
    fi
    [[ -z $failed_endpoint_ids || $failed_endpoint_ids == None ]] || {
      log "AWS refused to delete GuardDuty endpoint: $failed_endpoint_ids"
      return 1
    }
    return 0
  fi

  if ! security_group_json=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --output json); then
    log "Unable to inspect security groups while stack deletion is stalled"
    return 1
  fi
  if ! matching_groups=$(printf '%s' "$security_group_json" | jq -c \
    --arg name "$group_name" \
    --arg description "$group_description" \
    '[.SecurityGroups[]? | select(
      .GroupName == $name and
      .Description == $description and
      any(.Tags[]?; .Key == "GuardDutyManaged" and .Value == "true")
    )]'); then
    log "Unable to parse security group inventory while stack deletion is stalled"
    return 1
  fi
  group_count=$(printf '%s' "$matching_groups" | jq -r 'length')
  if (( group_count > 1 )); then
    log "Refusing automatic cleanup: found $group_count matching GuardDuty security groups in VPC $VPC_ID"
    return 1
  fi
  (( group_count == 1 )) || return 0

  group_id=$(printf '%s' "$matching_groups" | jq -r '.[0].GroupId')
  [[ $group_id =~ ^sg-[A-Za-z0-9]+$ ]] || {
    log "Refusing automatic cleanup: GuardDuty security group returned an invalid ID"
    return 1
  }
  log "Deleting orphaned GuardDuty security group $group_id from managed VPC $VPC_ID"
  if ! delete_error=$(aws ec2 delete-security-group \
    --region "$AWS_REGION" \
    --group-id "$group_id" 2>&1); then
    if [[ $delete_error == *DependencyViolation* ]]; then
      return 0
    fi
    log "Unable to delete orphaned GuardDuty security group $group_id: $delete_error"
    return 1
  fi
}

wait_for_managed_stack_deletion() {
  local deadline=$((SECONDS + STACK_WAIT_SECONDS))
  local dependency_check_at=$((SECONDS + STACK_DEPENDENCY_GRACE_SECONDS))
  local stack_status

  while :; do
    if stack_status=$(aws cloudformation describe-stacks \
      --stack-name "$VPC_STACK_ID" \
      --region "$AWS_REGION" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>&1); then
      case "$stack_status" in
        DELETE_COMPLETE) return 0 ;;
        DELETE_IN_PROGRESS) ;;
        *)
          log "Managed stack entered unexpected status $stack_status during deletion"
          return 1
          ;;
      esac
    elif [[ $stack_status == *ValidationError* && $stack_status == *"does not exist"* ]]; then
      return 0
    else
      log "Unable to inspect managed stack deletion: $stack_status"
      return 1
    fi

    if (( SECONDS >= dependency_check_at )); then
      remediate_guardduty_vpc_dependencies || return 1
    fi
    if (( SECONDS >= deadline )); then
      log "Timed out deleting managed stack; inspect dependencies in VPC $VPC_ID"
      return 1
    fi
    sleep "$POLL_SECONDS"
  done
}

verify_cluster_identity() {
  [[ -n $CLUSTER_ARN ]] || die "State has no cluster ARN; refusing Kubernetes mutation"
  local actual_arn actual_deployment_id
  actual_arn=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.arn' --output text)
  validate_cluster_arn "$actual_arn"
  [[ $actual_arn == "$CLUSTER_ARN" ]] || die "Cluster ARN mismatch; refusing same-name replacement"
  actual_deployment_id=$(aws eks list-tags-for-resource --resource-arn "$actual_arn" --region "$AWS_REGION" --query 'tags."twc-lab:deployment-id"' --output text)
  [[ $actual_deployment_id == "$DEPLOYMENT_ID" ]] || die "Cluster deployment tag mismatch"
}

recover_cluster_identity() {
  [[ -z $CLUSTER_ARN ]] || die "Cluster ARN recovery is only valid for missing state identity"
  local candidate_arn candidate_deployment_id
  candidate_arn=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.arn' --output text)
  validate_cluster_arn "$candidate_arn"
  candidate_deployment_id=$(aws eks list-tags-for-resource --resource-arn "$candidate_arn" --region "$AWS_REGION" --query 'tags."twc-lab:deployment-id"' --output text)
  [[ $candidate_deployment_id == "$DEPLOYMENT_ID" ]] || die "Live cluster is not owned by deployment $DEPLOYMENT_ID; refusing adoption"
  CLUSTER_ARN=$candidate_arn
  write_state
}

verify_stack_identity() {
  [[ -n $VPC_STACK_ID ]] || die "State has no stack ID; refusing stack mutation"
  local actual_id actual_cluster parameter_deployment tag_deployment
  actual_id=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackId' --output text)
  validate_stack_id "$actual_id"
  [[ $actual_id == "$VPC_STACK_ID" ]] || die "Stack ID mismatch; refusing same-name replacement"
  actual_cluster=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Parameters[?ParameterKey=='ClusterName'].ParameterValue | [0]" --output text)
  parameter_deployment=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Parameters[?ParameterKey=='DeploymentId'].ParameterValue | [0]" --output text)
  tag_deployment=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Tags[?Key=='twc-lab:deployment-id'].Value | [0]" --output text)
  [[ $actual_cluster == "$CLUSTER_NAME" ]] || die "Stack cluster parameter mismatch"
  [[ $parameter_deployment == "$DEPLOYMENT_ID" && $tag_deployment == "$DEPLOYMENT_ID" ]] || die "Stack deployment identity mismatch"
}

recover_stack_identity() {
  [[ -z $VPC_STACK_ID ]] || die "Stack ID recovery is only valid for missing state identity"
  local candidate_id actual_cluster parameter_deployment tag_deployment
  candidate_id=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query 'Stacks[0].StackId' --output text)
  validate_stack_id "$candidate_id"
  actual_cluster=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Parameters[?ParameterKey=='ClusterName'].ParameterValue | [0]" --output text)
  parameter_deployment=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Parameters[?ParameterKey=='DeploymentId'].ParameterValue | [0]" --output text)
  tag_deployment=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Tags[?Key=='twc-lab:deployment-id'].Value | [0]" --output text)
  [[ $actual_cluster == "$CLUSTER_NAME" ]] || die "Stack cluster parameter mismatch; refusing adoption"
  [[ $parameter_deployment == "$DEPLOYMENT_ID" && $tag_deployment == "$DEPLOYMENT_ID" ]] || die "Stack deployment identity mismatch; refusing adoption"
  VPC_STACK_ID=$candidate_id
  write_state
}

confirm_action() {
  local action=$1 expected=$2 answer
  [[ ${CONFIRM:-0} == 1 ]] && return 0
  [[ -t 0 ]] || die "Refusing to $action without a terminal; set CONFIRM=1 to confirm"
  printf 'Type %s to confirm %s: ' "$expected" "$action" >&2
  IFS= read -r answer
  [[ $answer == "$expected" ]] || die "Confirmation did not match"
}

current_account() {
  aws sts get-caller-identity --query Account --output text --region "$AWS_REGION"
}

verify_current_account() {
  local actual
  actual=$(current_account)
  validate_account_id "$actual"
  [[ $actual == "$ACCOUNT_ID" ]] || die "AWS account mismatch: state is $ACCOUNT_ID, caller is $actual"
}

split_csv() {
  local csv=$1
  local old_ifs=$IFS
  IFS=',' read -r -a CSV_VALUES <<<"$csv"
  IFS=$old_ifs
}

statefulset_for_service() {
  case "$1" in
    cassandra) printf '%s\n' twc-lab-cassandra ;;
    zookeeper) printf '%s\n' twc-lab-zookeeper ;;
    artemis) printf '%s\n' twc-lab-artemis ;;
    *) die "SERVICE must be one of: cassandra, zookeeper, artemis" ;;
  esac
}
