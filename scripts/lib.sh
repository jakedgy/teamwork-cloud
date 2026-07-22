#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly LAB_DIR="$PWD/.twc-lab"
readonly STATE_FILE="$LAB_DIR/state.env"
readonly CLUSTER_CONFIG="$LAB_DIR/cluster.yaml"
readonly SECRETS_FILE="$LAB_DIR/secrets.yaml"

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
  ACCOUNT_ID= AWS_REGION= CLUSTER_NAME= NETWORK_MODE= VPC_ID= SUBNET_IDS=
  STACK_NAME= FAILED_SERVICE= NLB_HOSTNAME=
  while IFS='=' read -r key value || [[ -n ${key:-} ]]; do
    [[ -n ${key:-} ]] || continue
    case "$key" in
      ACCOUNT_ID|AWS_REGION|CLUSTER_NAME|NETWORK_MODE|VPC_ID|SUBNET_IDS|STACK_NAME|FAILED_SERVICE|NLB_HOSTNAME)
        [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "Invalid newline in state value"
        printf -v "$key" '%s' "$value"
        ;;
      *) die "Unknown key '$key' in state file" ;;
    esac
  done <"$STATE_FILE"
  [[ -n $ACCOUNT_ID && -n $AWS_REGION && -n $CLUSTER_NAME && -n $NETWORK_MODE ]] || die "State file is incomplete"
  validate_account_id "$ACCOUNT_ID"
  validate_region "$AWS_REGION"
  validate_simple_name CLUSTER_NAME "$CLUSTER_NAME"
  validate_network_mode "$NETWORK_MODE"
  [[ $VPC_ID =~ ^vpc-[A-Za-z0-9]+$ ]] || die "State contains an invalid VPC ID"
  split_csv "$SUBNET_IDS"
  (( ${#CSV_VALUES[@]} >= 2 )) || die "State must contain at least two subnet IDs"
  local subnet
  for subnet in "${CSV_VALUES[@]}"; do
    [[ $subnet =~ ^subnet-[A-Za-z0-9]+$ ]] || die "State contains an invalid subnet ID"
  done
  case "$FAILED_SERVICE" in
    ''|cassandra|zookeeper|artemis) ;;
    *) die "State contains an invalid failed service" ;;
  esac
  [[ -z $NLB_HOSTNAME || $NLB_HOSTNAME =~ ^[A-Za-z0-9.-]+$ ]] || die "State contains an invalid NLB hostname"
  if [[ $NETWORK_MODE == managed ]]; then
    [[ $STACK_NAME == "${CLUSTER_NAME}-vpc" ]] || die "Managed stack is outside the cluster's scope"
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
    printf 'VPC_ID=%s\n' "${VPC_ID:-}"
    printf 'SUBNET_IDS=%s\n' "${SUBNET_IDS:-}"
    printf 'STACK_NAME=%s\n' "${STACK_NAME:-}"
    printf 'FAILED_SERVICE=%s\n' "${FAILED_SERVICE:-}"
    printf 'NLB_HOSTNAME=%s\n' "${NLB_HOSTNAME:-}"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
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
