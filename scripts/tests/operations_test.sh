#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/bin"
CALLS="$TEST_ROOT/calls.log"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat >"$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws %s\n' "$*" >>"$FAKE_CALLS"
case "${1:-} ${2:-}" in
  "sts get-caller-identity") printf '%s\n' "${FAKE_ACCOUNT:-111122223333}" ;;
  "eks describe-cluster")
    if [[ -n ${FAKE_CLUSTER_ERROR:-} ]]; then
      printf '%s\n' "$FAKE_CLUSTER_ERROR" >&2
      exit 254
    fi
    if [[ "${FAKE_CLUSTER_EXISTS:-0}" != 1 && ! -f "${FAKE_CLUSTER_MARK:-/nonexistent}" ]]; then
      printf 'ResourceNotFoundException\n' >&2
      exit 254
    fi
    if [[ "$*" == *"cluster.arn"* ]]; then
      printf '%s\n' "${FAKE_CLUSTER_ARN:-arn:aws:eks:us-east-2:111122223333:cluster/twc-lab}"
    else
      printf '%s\n' ACTIVE
    fi
    ;;
  "eks list-tags-for-resource")
    if [[ -n ${FAKE_CLUSTER_DEPLOYMENT_ID+x} ]]; then
      printf '%s\n' "$FAKE_CLUSTER_DEPLOYMENT_ID"
    elif [[ -f "${FAKE_CLUSTER_TAG_MARK:-/nonexistent}" ]]; then
      sed -n '1p' "$FAKE_CLUSTER_TAG_MARK"
    else
      printf '%s\n' None
    fi
    ;;
  "eks tag-resource")
    [[ "${FAKE_CLUSTER_TAG_FAIL:-0}" != 1 ]] || exit 1
    tag_value=${*: -1}
    printf '%s\n' "${tag_value#twc-lab:deployment-id=}" >"$FAKE_CLUSTER_TAG_MARK"
    ;;
  "eks update-kubeconfig")
    previous=
    for argument in "$@"; do
      if [[ $previous == --kubeconfig ]]; then : >"$argument"; fi
      previous=$argument
    done
    ;;
  "ec2 describe-vpcs") printf '%s\n' "${FAKE_VPCS:-vpc-123456}" ;;
  "ec2 describe-subnets")
    if [[ "$*" == *"Subnets[].[AvailabilityZone,SubnetId]"* ]]; then
      printf '%b\n' "${FAKE_AZ_ROWS:-us-east-2a\tsubnet-a\nus-east-2b\tsubnet-b}"
    elif [[ "$*" == *"AvailabilityZone,SubnetId"* ]]; then
      if [[ "${FAKE_REAL_AWS_TEXT:-0}" == 1 ]]; then
        printf -v rows '%b' "${FAKE_AZ_ROWS:-us-east-2a\tsubnet-a\nus-east-2b\tsubnet-b}"
        printf '%s\n' "${rows//$'\n'/$'\t'}"
      else
        printf '%b\n' "${FAKE_AZ_ROWS:-us-east-2a\tsubnet-a\nus-east-2b\tsubnet-b}"
      fi
    elif [[ "$*" == *"Subnets[].[SubnetId,AvailabilityZone"* ]]; then
      printf '%b\n' "${FAKE_SUBNET_ROWS:-subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1}"
    else
      [[ "$*" == *'join(`\t`'* ]] || exit 2
      if [[ "${FAKE_REAL_AWS_TEXT:-0}" == 1 ]]; then
        printf -v rows '%b' "${FAKE_SUBNET_ROWS:-subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1}"
        printf '%s\n' "${rows//$'\n'/$'\t'}"
      else
        printf '%b\n' "${FAKE_SUBNET_ROWS:-subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1}"
      fi
    fi
    ;;
  "ec2 describe-route-tables")
    if [[ "$*" == *"association.subnet-id"* ]]; then
      printf '%s\n' "${FAKE_EXPLICIT_ROUTE_TABLE_ID:-rtb-selected}"
    elif [[ "$*" == *"association.main"* ]]; then
      printf '%s\n' "${FAKE_MAIN_ROUTE_TABLE_ID:-rtb-main}"
    elif [[ "$*" == *"--route-table-ids"* ]]; then
      printf '%s\n' "${FAKE_SELECTED_ROUTE:-igw-123456}"
    else
      printf '%s\n' "${FAKE_DEFAULT_ROUTES:-igw-123456}"
    fi
    ;;
  "cloudformation describe-stacks")
    if [[ -n ${FAKE_STACK_ERROR:-} ]]; then
      printf '%s\n' "$FAKE_STACK_ERROR" >&2
      exit 254
    fi
    if [[ "${FAKE_STACK_EXISTS:-0}" != 1 && ! -f "${FAKE_STACK_MARK:-/nonexistent}" ]]; then
      printf 'ValidationError: Stack does not exist\n' >&2
      exit 254
    fi
    case "$*" in
      *"twc-lab:managed"*) printf '%s\n' "${FAKE_STACK_TAG:-true}" ;;
      *"ParameterKey=='ClusterName'"*) printf '%s\n' "${FAKE_STACK_CLUSTER:-twc-lab}" ;;
      *"ParameterKey=='DeploymentId'"*) printf '%s\n' "${FAKE_STACK_DEPLOYMENT_ID:-0123456789abcdef0123456789abcdef}" ;;
      *"twc-lab:deployment-id"*) printf '%s\n' "${FAKE_STACK_DEPLOYMENT_ID:-0123456789abcdef0123456789abcdef}" ;;
      *"StackId"*) printf '%s\n' "${FAKE_STACK_ID:-arn:aws:cloudformation:us-east-2:111122223333:stack/twc-lab-vpc/stack123}" ;;
      *"OutputKey=='VpcId'"*) printf '%s\n' "${FAKE_VPC_OUTPUT:-vpc-managed}" ;;
      *"OutputKey=='PublicSubnetIds'"*) printf '%s\n' "${FAKE_SUBNET_OUTPUT:-subnet-a,subnet-b}" ;;
      *) printf '%s\n' "${FAKE_STACK_STATUS:-CREATE_COMPLETE}" ;;
    esac
    ;;
  "cloudformation deploy")
    [[ "$*" == *"--tags twc-lab:managed=true"* ]] || exit 2
    : >"${FAKE_STACK_MARK}"
    [[ "${FAKE_STACK_DEPLOY_FAIL:-0}" != 1 ]] || exit 1
    ;;
  "cloudformation delete-stack")
    [[ "${FAKE_DELETE_STACK_FAIL:-0}" != 1 ]] || exit 1
    rm -f "$FAKE_STACK_MARK"
    ;;
  "cloudformation wait") [[ "${FAKE_STACK_DELETE_FAIL:-0}" != 1 ]] ;;
  "elbv2 describe-load-balancers")
    if [[ "$*" == *"DNSName=="* ]]; then
      if [[ "${FAKE_NLB_LOOKUP_ERROR:-0}" == 1 ]]; then
        printf 'AccessDeniedException\n' >&2
        exit 254
      fi
      printf '%s\n' "${FAKE_NLB_ARNS:-None}"
    else
      printf '%s\n' "${FAKE_ALL_ELB_ARNS:-None}"
    fi
    ;;
  "elbv2 describe-tags") printf '%s\n' "${FAKE_RESIDUAL_ELBS:-None}" ;;
  "ec2 describe-volumes")
    if [[ "$*" == *"--volume-ids"* ]]; then
      if [[ "${FAKE_VOLUME_LOOKUP_ERROR:-0}" == 1 ]]; then printf 'AccessDeniedException\n' >&2; exit 254; fi
      printf 'InvalidVolume.NotFound\n' >&2
      exit 254
    fi
    printf '%s\n' "${FAKE_RESIDUAL_VOLUMES:-None}"
    ;;
  *) printf 'unexpected aws command: %s\n' "$*" >&2; exit 97 ;;
esac
EOF

cat >"$FAKE_BIN/eksctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'eksctl %s\n' "$*" >>"$FAKE_CALLS"
case "${1:-} ${2:-}" in "create cluster"|"delete cluster") ;; *) printf 'unexpected eksctl command\n' >&2; exit 97 ;; esac
if [[ "${1:-} ${2:-}" == "create cluster" ]]; then
  : >"${FAKE_CLUSTER_MARK}"
  config_path=
  previous=
  for argument in "$@"; do
    if [[ $previous == --config-file ]]; then config_path=$argument; fi
    previous=$argument
  done
  sed -n 's/^    twc-lab:deployment-id: //p' "$config_path" >"$FAKE_CLUSTER_TAG_MARK"
  if [[ "${FAKE_CREATE_CLUSTER_FAIL:-0}" == 1 ]]; then exit 1; fi
fi
if [[ "${1:-} ${2:-}" == "delete cluster" && "${FAKE_CLUSTER_DELETE_FAIL:-0}" == 1 ]]; then
  exit 1
fi
if [[ "${1:-} ${2:-}" == "delete cluster" ]]; then
  rm -f "$FAKE_CLUSTER_MARK"
fi
EOF

cat >"$FAKE_BIN/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s KUBECONFIG=%s\n' "$*" "${KUBECONFIG:-unset}" >>"$FAKE_CALLS"
[[ "${FAKE_KUBE_API_UNAVAILABLE:-0}" != 1 ]] || { printf 'Kubernetes API unavailable\n' >&2; exit 98; }
[[ "${KUBECONFIG:-}" == */.twc-lab/kubeconfig ]] || { printf 'unscoped helm command\n' >&2; exit 97; }
case "${1:-} ${2:-}" in "repo add"|"repo update"|"upgrade --install"|"list --all-namespaces"|"uninstall twc-lab"|"uninstall ingress-nginx") ;; *) printf 'unexpected helm command: %s\n' "$*" >&2; exit 97 ;; esac
if [[ "${1:-}" == list ]]; then
  printf '%s\n' '[{"name":"ingress-nginx","namespace":"ingress-nginx","status":"deployed"},{"name":"twc-lab","namespace":"twc-lab","status":"deployed"}]'
fi
if [[ "${1:-}" == uninstall && "${FAKE_HELM_UNINSTALL_FAIL:-0}" == 1 ]]; then
  exit 1
fi
EOF

cat >"$FAKE_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s KUBECONFIG=%s\n' "$*" "${KUBECONFIG:-unset}" >>"$FAKE_CALLS"
[[ "${FAKE_KUBE_API_UNAVAILABLE:-0}" != 1 ]] || { printf 'Kubernetes API unavailable\n' >&2; exit 98; }
[[ "${KUBECONFIG:-}" == */.twc-lab/kubeconfig ]] || { printf 'unscoped kubectl command\n' >&2; exit 97; }
if [[ "$*" == *"rollout status"* && "${FAKE_ROLLOUT_FAIL:-0}" == 1 ]]; then
  exit 1
fi
case "$*" in
  *"get service ingress-nginx-controller"*) printf '%s\n' "${FAKE_NLB_HOST:-lab.example.test}" ;;
  *"get service twc-lab"*) printf '%s\n' "${FAKE_APP_HOST:-lab.example.test}" ;;
  *"get statefulset"*) printf '%s\n' "${FAKE_REPLICAS:-1}" ;;
  *"get pods"*"--output name"*) printf '%s\n' 'pod/twc-lab-simulator-abc' 'pod/twc-lab-artemis-0' ;;
  *"get persistentvolumeclaims"*"--output json"*)
    if [[ "${FAKE_PVC_PRESENT:-0}" == 1 ]]; then printf '%s\n' '{"items":[{"spec":{"volumeName":"pv-lab123"}}]}'; else printf '%s\n' '{"items":[]}'; fi
    ;;
  *"get persistentvolumeclaims"*"--output name"*) printf '%s\n' 'persistentvolumeclaim/data-twc-lab-artemis-0' ;;
  *"get persistentvolume"*"--output json"*) printf '%s\n' '{"spec":{"csi":{"volumeHandle":"vol-pvc123"}}}' ;;
  *"get persistentvolume"*"--output name"*) ;;
  *"get --raw"*"api/health"*) printf '%s\n' '{"status":"UP","layers":4}' ;;
  *"wait "*|*"scale statefulset"*|*"rollout status"*|*"delete service"*) ;;
  *"delete persistentvolumeclaims"*) : >"${FAKE_PVC_DELETED_MARK}" ;;
  *) printf 'unexpected kubectl command: %s\n' "$*" >&2; exit 97 ;;
esac
EOF

cat >"$FAKE_BIN/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "rand -hex 16" ]] || { printf 'unexpected openssl command\n' >&2; exit 97; }
printf '0123456789abcdef0123456789abcdef\n'
EOF
cat >"$FAKE_BIN/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s\n' "$*" >>"$FAKE_CALLS"
printf 'unexpected make invocation\n' >&2
exit 97
EOF
chmod +x "$FAKE_BIN"/*

NO_MAKE_BIN="$TEST_ROOT/no-make-bin"
mkdir -p "$NO_MAKE_BIN"
ln -s "$(command -v env)" "$NO_MAKE_BIN/env"
ln -s "$(command -v bash)" "$NO_MAKE_BIN/bash"
ln -s "$(command -v dirname)" "$NO_MAKE_BIN/dirname"
for tool in aws eksctl helm kubectl openssl; do
  ln -s "$FAKE_BIN/$tool" "$NO_MAKE_BIN/$tool"
done
ln -s "$(command -v jq)" "$NO_MAKE_BIN/jq"

NO_KUBE_BIN="$TEST_ROOT/no-kube-bin"
mkdir -p "$NO_KUBE_BIN"
ln -s "$(command -v env)" "$NO_KUBE_BIN/env"
ln -s "$(command -v bash)" "$NO_KUBE_BIN/bash"
ln -s "$(command -v dirname)" "$NO_KUBE_BIN/dirname"
ln -s "$FAKE_BIN/aws" "$NO_KUBE_BIN/aws"

export FAKE_CALLS="$CALLS"
export FAKE_STACK_MARK="$TEST_ROOT/stack-created"
export FAKE_CLUSTER_MARK="$TEST_ROOT/cluster-created"
export FAKE_PVC_DELETED_MARK="$TEST_ROOT/pvc-deleted"
export FAKE_CLUSTER_TAG_MARK="$TEST_ROOT/cluster-deployment-tag"
export PATH="$FAKE_BIN:/usr/bin:/bin"
export KUBECONFIG="$TEST_ROOT/external-user-context"

pass=0
fail=0

if grep -Fxq '/.twc-lab/' "$ROOT/.gitignore"; then
  printf 'ok - generated state and secrets are ignored by git\n'
  pass=$((pass + 1))
else
  printf 'not ok - generated state and secrets are ignored by git\n' >&2
  fail=$((fail + 1))
fi

new_case() {
  CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXX")
  : >"$CALLS"
  rm -f "$FAKE_STACK_MARK"
  rm -f "$FAKE_CLUSTER_MARK"
  rm -f "$FAKE_PVC_DELETED_MARK"
  rm -f "$FAKE_CLUSTER_TAG_MARK"
}

run_script() {
  local script=$1
  shift
  (cd "$CASE_DIR" && env \
    -u AWS_DEFAULT_REGION -u AWS_PROFILE -u AWS_REGION \
    -u CLUSTER_NAME -u CONFIRM -u JSON -u NETWORK_MODE \
    -u PUBLIC_SUBNET_IDS -u SIMULATOR_IMAGE_REPOSITORY \
    -u SIMULATOR_IMAGE_TAG -u SUBNET_IDS -u VPC_ID \
    "$@" "$ROOT/scripts/$script")
}

record() {
  local name=$1 status=$2
  if [[ $status == pass ]]; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

expect_fail() {
  local name=$1
  shift
  if "$@" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
    record "$name" fail
  else
    record "$name" pass
  fi
}

expect_ok() {
  local name=$1
  shift
  if "$@" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
    record "$name" pass
  else
    record "$name" fail
    sed -n '1,80p' "$TEST_ROOT/err" >&2
  fi
}

assert_no_call() {
  local name=$1 pattern=$2
  if grep -Fq "$pattern" "$CALLS"; then record "$name" fail; else record "$name" pass; fi
}

assert_order() {
  local name=$1 first=$2 second=$3 a b
  a=$(grep -Fn "$first" "$CALLS" | head -1 | cut -d: -f1 || true)
  b=$(grep -Fn "$second" "$CALLS" | head -1 | cut -d: -f1 || true)
  if [[ -n $a && -n $b && $a -lt $b ]]; then record "$name" pass; else record "$name" fail; fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

write_state() {
  local mode=$1
  mkdir -p "$CASE_DIR/.twc-lab"
  cat >"$CASE_DIR/.twc-lab/state.env" <<EOF
ACCOUNT_ID=111122223333
AWS_REGION=us-east-2
CLUSTER_NAME=twc-lab
NETWORK_MODE=$mode
PHASE=DEPLOYED
DEPLOYMENT_ID=0123456789abcdef0123456789abcdef
CLUSTER_ARN=arn:aws:eks:us-east-2:111122223333:cluster/twc-lab
VPC_ID=vpc-123456
PUBLIC_SUBNET_IDS=subnet-a,subnet-b
STACK_NAME=twc-lab-vpc
VPC_STACK_ID=arn:aws:cloudformation:us-east-2:111122223333:stack/twc-lab-vpc/stack123
PENDING_VOLUME_IDS=
SIMULATOR_IMAGE_REPOSITORY=
SIMULATOR_IMAGE_TAG=
FAILED_SERVICE=
NLB_HOSTNAME=lab.example.test
EOF
  chmod 600 "$CASE_DIR/.twc-lab/state.env"
  if [[ $mode == managed ]]; then
    : >"$FAKE_STACK_MARK"
  fi
  : >"$FAKE_CLUSTER_MARK"
  printf '%s\n' 0123456789abcdef0123456789abcdef >"$FAKE_CLUSTER_TAG_MARK"
}

new_case
expect_fail "invalid mode is rejected" run_script preflight.sh NETWORK_MODE=bogus
assert_no_call "invalid mode is rejected before AWS" "aws "

new_case
expect_fail "existing mode requires a VPC" run_script preflight.sh NETWORK_MODE=existing VPC_ID=

new_case
expect_fail "preflight requires make" run_script preflight.sh PATH="$NO_MAKE_BIN"

new_case
expect_fail "cluster lookup errors are not mistaken for absence" run_script preflight.sh FAKE_CLUSTER_ERROR=AccessDeniedException

new_case
expect_ok "managed preflight accepts absent cluster and stack" run_script preflight.sh
if ! grep -Fq 'Command failed at line' "$TEST_ROOT/err"; then
  record "expected absence probes do not emit failure diagnostics" pass
else
  record "expected absence probes do not emit failure diagnostics" fail
fi

new_case
expect_fail "existing mode requires two public subnets" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a

new_case
expect_fail "existing mode requires exactly one matching VPC" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b $'FAKE_VPCS=vpc-123456\tvpc-other'

new_case
expect_ok "existing preflight parses real AWS text subnet rows" run_script preflight.sh \
  NETWORK_MODE=existing VPC_ID=vpc-123456 \
  PUBLIC_SUBNET_IDS=subnet-a,subnet-b,subnet-c \
  $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1\nsubnet-c\tus-east-2c\t32\tTrue\t1' \
  FAKE_REAL_AWS_TEXT=1

new_case
expect_fail "existing preflight rejects a missing subnet availability zone" run_script preflight.sh \
  NETWORK_MODE=existing VPC_ID=vpc-123456 \
  PUBLIC_SUBNET_IDS=subnet-a,subnet-b \
  $'FAKE_SUBNET_ROWS=subnet-a\tNone\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1'
if grep -Fxq '[twc-lab] ERROR: AWS returned subnet subnet-a without an availability zone' "$TEST_ROOT/err"; then
  record "missing subnet availability zone has an exact error" pass
else
  record "missing subnet availability zone has an exact error" fail
fi

new_case
expect_fail "existing subnets must span AZs" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2a\t32\tTrue\t1'

new_case
expect_fail "existing subnets cannot share an availability zone" run_script preflight.sh \
  NETWORK_MODE=existing VPC_ID=vpc-123456 \
  PUBLIC_SUBNET_IDS=subnet-a,subnet-b,subnet-c \
  $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2a\t32\tTrue\t1\nsubnet-c\tus-east-2b\t32\tTrue\t1'
if grep -Fxq '[twc-lab] ERROR: Selected subnets must use distinct availability zones' "$TEST_ROOT/err"; then
  record "duplicate subnet availability zone has a clear error" pass
else
  record "duplicate subnet availability zone has a clear error" fail
fi

new_case
expect_fail "existing subnets need sixteen free IPs" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t15\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1'

new_case
expect_fail "existing subnets map public IPs" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tFalse\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1'

new_case
expect_fail "existing VPC has an IGW default route" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b FAKE_SELECTED_ROUTE=None

new_case
expect_fail "selected subnet cannot borrow an unrelated IGW route" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b FAKE_EXPLICIT_ROUTE_TABLE_ID=rtb-selected FAKE_SELECTED_ROUTE=None FAKE_DEFAULT_ROUTES=igw-unrelated

new_case
expect_fail "existing subnets carry public ELB role tags" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\tNone\nsubnet-b\tus-east-2b\t32\tTrue\t1'

new_case
expect_ok "managed deploy succeeds with fake CLIs" run_script deploy.sh CONFIRM=1
assert_order "managed stack precedes cluster creation" "aws cloudformation deploy" "eksctl create cluster"
assert_order "cluster precedes ingress installation" "eksctl create cluster" "helm upgrade --install ingress-nginx"
assert_order "ingress precedes app installation" "helm upgrade --install ingress-nginx" "helm upgrade --install twc-lab"
if grep -Fq -- "--kubeconfig $CASE_DIR/.twc-lab/kubeconfig" "$CALLS" && ! grep -Eq '^(helm|kubectl).*KUBECONFIG=unset$' "$CALLS"; then record "deploy uses only the dedicated lab kubeconfig" pass; else record "deploy uses only the dedicated lab kubeconfig" fail; fi
if [[ $(file_mode "$CASE_DIR/.twc-lab/state.env") == 600 ]]; then record "state file permissions are 0600" pass; else record "state file permissions are 0600" fail; fi
if [[ $(file_mode "$CASE_DIR/.twc-lab/secrets.yaml") == 600 ]]; then record "secrets file permissions are 0600" pass; else record "secrets file permissions are 0600" fail; fi
if grep -Eq '^secrets:$' "$CASE_DIR/.twc-lab/secrets.yaml" && grep -Eq '^  artemisPassword: "[0-9a-f]{32}"$' "$CASE_DIR/.twc-lab/secrets.yaml"; then record "secret uses the chart password key and 32 characters" pass; else record "secret uses the chart password key and 32 characters" fail; fi
if [[ $(cut -d= -f1 "$CASE_DIR/.twc-lab/state.env" | tr '\n' ' ') == "ACCOUNT_ID AWS_REGION CLUSTER_NAME NETWORK_MODE PHASE DEPLOYMENT_ID CLUSTER_ARN VPC_ID PUBLIC_SUBNET_IDS STACK_NAME VPC_STACK_ID PENDING_VOLUME_IDS SIMULATOR_IMAGE_REPOSITORY SIMULATOR_IMAGE_TAG FAILED_SERVICE NLB_HOSTNAME " ]]; then record "state contains only fixed keys" pass; else record "state contains only fixed keys" fail; fi
if grep -q '^DEPLOYMENT_ID=' "$CASE_DIR/.twc-lab/state.env" && grep -q '^CLUSTER_ARN=' "$CASE_DIR/.twc-lab/state.env" && grep -q '^VPC_STACK_ID=' "$CASE_DIR/.twc-lab/state.env"; then record "state records deployment, cluster, and stack identities" pass; else record "state records deployment, cluster, and stack identities" fail; fi
if grep -q '^PHASE=DEPLOYED$' "$CASE_DIR/.twc-lab/state.env" && grep -q '^PENDING_VOLUME_IDS=$' "$CASE_DIR/.twc-lab/state.env"; then record "deployed state records lifecycle phase and pending storage" pass; else record "deployed state records lifecycle phase and pending storage" fail; fi
if grep -Fq 'DeploymentId=0123456789abcdef0123456789abcdef' "$CALLS" && grep -Fq 'twc-lab:deployment-id=0123456789abcdef0123456789abcdef' "$CALLS"; then record "deployment identity tags both stack and cluster" pass; else record "deployment identity tags both stack and cluster" fail; fi
if grep -Fq 'nodePools:' "$CASE_DIR/.twc-lab/cluster.yaml" && grep -Fq 'general-purpose' "$CASE_DIR/.twc-lab/cluster.yaml" && grep -Fq 'system' "$CASE_DIR/.twc-lab/cluster.yaml"; then record "renderer enables both Auto Mode pools" pass; else record "renderer enables both Auto Mode pools" fail; fi
if grep -Fq 'twc-lab:deployment-id: 0123456789abcdef0123456789abcdef' "$CASE_DIR/.twc-lab/cluster.yaml"; then record "renderer requests cluster ownership tag atomically" pass; else record "renderer requests cluster ownership tag atomically" fail; fi
if grep -Fq 'http://lab.example.test/webapp' "$TEST_ROOT/out" && grep -Fq 'http://lab.example.test/admin' "$TEST_ROOT/out" && grep -Fq 'http://lab.example.test/admin/license' "$TEST_ROOT/out" && ! grep -Fq '/authentication' "$TEST_ROOT/out"; then record "deploy prints the required three URLs" pass; else record "deploy prints the required three URLs" fail; fi
if ! grep -Fq 'simulator.image.repository' "$CALLS" && ! grep -Fq 'simulator.image.tag' "$CALLS"; then record "default deploy leaves simulator image values unchanged" pass; else record "default deploy leaves simulator image values unchanged" fail; fi

new_case
expect_ok "managed deploy parses real AWS text subnet rows" run_script deploy.sh FAKE_REAL_AWS_TEXT=1 CONFIRM=1

new_case
expect_ok "existing deploy accepts three distinct subnet availability zones" run_script deploy.sh \
  NETWORK_MODE=existing VPC_ID=vpc-123456 \
  PUBLIC_SUBNET_IDS=subnet-a,subnet-b,subnet-c \
  $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1\nsubnet-c\tus-east-2c\t32\tTrue\t1' \
  $'FAKE_AZ_ROWS=us-east-2a\tsubnet-a\nus-east-2b\tsubnet-b\nus-east-2c\tsubnet-c' \
  FAKE_REAL_AWS_TEXT=1 CONFIRM=1

new_case
expect_fail "renderer rejects an omitted requested subnet" run_script deploy.sh \
  $'FAKE_AZ_ROWS=us-east-2a\tsubnet-a' CONFIRM=1
if grep -Fxq '[twc-lab] ERROR: Could not discover every requested subnet availability zone' "$TEST_ROOT/err"; then
  record "omitted subnet has an exact renderer error" pass
else
  record "omitted subnet has an exact renderer error" fail
fi

new_case
expect_fail "renderer rejects a duplicate returned subnet" run_script deploy.sh \
  $'FAKE_AZ_ROWS=us-east-2a\tsubnet-a\nus-east-2b\tsubnet-a' CONFIRM=1
if grep -Fxq '[twc-lab] ERROR: AWS returned subnet subnet-a more than once' "$TEST_ROOT/err"; then
  record "duplicate returned subnet has an exact renderer error" pass
else
  record "duplicate returned subnet has an exact renderer error" fail
fi

new_case
expect_fail "renderer rejects multiple subnets in one availability zone" run_script deploy.sh \
  $'FAKE_AZ_ROWS=us-east-2a\tsubnet-a\nus-east-2a\tsubnet-b' CONFIRM=1
if grep -Fxq '[twc-lab] ERROR: Selected subnets must use distinct availability zones' "$TEST_ROOT/err"; then
  record "duplicate availability zone has an exact renderer error" pass
else
  record "duplicate availability zone has an exact renderer error" fail
fi

new_case
expect_fail "simulator image repository requires a tag" run_script deploy.sh SIMULATOR_IMAGE_REPOSITORY=ghcr.io/jakedgy/teamwork-cloud CONFIRM=1
assert_no_call "unpaired simulator repository is rejected before AWS" "aws "

new_case
expect_fail "simulator image tag requires a repository" run_script deploy.sh SIMULATOR_IMAGE_TAG=smoke-123 CONFIRM=1
assert_no_call "unpaired simulator tag is rejected before AWS" "aws "

new_case
expect_fail "unsafe simulator image repository is rejected" run_script deploy.sh SIMULATOR_IMAGE_REPOSITORY='ghcr.io/Jakedgy/teamwork-cloud;bad' SIMULATOR_IMAGE_TAG=smoke-123 CONFIRM=1
assert_no_call "unsafe simulator repository is rejected before AWS" "aws "

new_case
expect_fail "unsafe simulator image tag is rejected" run_script deploy.sh SIMULATOR_IMAGE_REPOSITORY=ghcr.io/jakedgy/teamwork-cloud SIMULATOR_IMAGE_TAG='bad tag' CONFIRM=1
assert_no_call "unsafe simulator tag is rejected before AWS" "aws "

new_case
too_long_image_tag=$(printf 'a%.0s' {1..129})
expect_fail "simulator image tag length is bounded" run_script deploy.sh SIMULATOR_IMAGE_REPOSITORY=ghcr.io/jakedgy/teamwork-cloud "SIMULATOR_IMAGE_TAG=$too_long_image_tag" CONFIRM=1
assert_no_call "oversized simulator tag is rejected before AWS" "aws "

new_case
expect_ok "paired simulator image override deploys" run_script deploy.sh SIMULATOR_IMAGE_REPOSITORY=ghcr.io/jakedgy/teamwork-cloud SIMULATOR_IMAGE_TAG=smoke-123 CONFIRM=1
if grep -Fq -- '--set-string simulator.image.repository=ghcr.io/jakedgy/teamwork-cloud --set-string simulator.image.tag=smoke-123' "$CALLS"; then record "simulator image override uses exact separate Helm values" pass; else record "simulator image override uses exact separate Helm values" fail; fi
if grep -q '^SIMULATOR_IMAGE_REPOSITORY=ghcr.io/jakedgy/teamwork-cloud$' "$CASE_DIR/.twc-lab/state.env" && grep -q '^SIMULATOR_IMAGE_TAG=smoke-123$' "$CASE_DIR/.twc-lab/state.env"; then record "simulator image override is persisted" pass; else record "simulator image override is persisted" fail; fi
: >"$CALLS"
expect_ok "simulator image override is reused on retry" run_script deploy.sh CONFIRM=1
if grep -Fq -- '--set-string simulator.image.repository=ghcr.io/jakedgy/teamwork-cloud --set-string simulator.image.tag=smoke-123' "$CALLS"; then record "retry reuses exact simulator Helm values" pass; else record "retry reuses exact simulator Helm values" fail; fi
: >"$CALLS"
expect_fail "conflicting simulator image override is rejected" run_script deploy.sh SIMULATOR_IMAGE_REPOSITORY=ghcr.io/jakedgy/teamwork-cloud SIMULATOR_IMAGE_TAG=smoke-456 CONFIRM=1
assert_no_call "conflicting simulator image override never reaches Helm" "helm "

new_case
expect_fail "preflight rejects an unrelated same-name stack" run_script preflight.sh FAKE_STACK_EXISTS=1 FAKE_STACK_TAG=false

new_case
expect_fail "preflight rejects a managed stack for another cluster" run_script preflight.sh FAKE_STACK_EXISTS=1 FAKE_STACK_CLUSTER=other-cluster

new_case
expect_fail "preflight rejects even tagged stacks without deployment state" run_script preflight.sh FAKE_STACK_EXISTS=1

new_case
expect_fail "managed deploy stops when stack lookup is unauthorized" run_script deploy.sh CONFIRM=1 FAKE_STACK_ERROR=AccessDeniedException
assert_no_call "stack lookup error prevents CloudFormation mutation" "aws cloudformation deploy"

new_case
expect_ok "documented PUBLIC_SUBNET_IDS deploy succeeds" run_script deploy.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b CONFIRM=1
assert_no_call "existing deploy never mutates CloudFormation" "aws cloudformation deploy"
expect_ok "existing deploy reuses its recorded state without repeated flags" run_script deploy.sh CONFIRM=1
assert_no_call "recorded existing mode still never mutates CloudFormation" "aws cloudformation deploy"
: >"$CALLS"
expect_fail "tracked deployment rejects conflicting network overrides" run_script deploy.sh NETWORK_MODE=existing VPC_ID=vpc-other PUBLIC_SUBNET_IDS=subnet-x,subnet-y CONFIRM=1
if grep -Fq 'VPC_ID=vpc-123456' "$CASE_DIR/.twc-lab/state.env"; then record "conflicting rerun preserves tracked network identity" pass; else record "conflicting rerun preserves tracked network identity" fail; fi

new_case
expect_ok "legacy SUBNET_IDS deploy remains compatible" run_script deploy.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b CONFIRM=1
if grep -q '^PUBLIC_SUBNET_IDS=subnet-a,subnet-b$' "$CASE_DIR/.twc-lab/state.env" && ! grep -q '^SUBNET_IDS=' "$CASE_DIR/.twc-lab/state.env"; then record "legacy subnet input migrates to canonical state" pass; else record "legacy subnet input migrates to canonical state" fail; fi

new_case
write_state existing
sed 's/^PUBLIC_SUBNET_IDS=/SUBNET_IDS=/' "$CASE_DIR/.twc-lab/state.env" >"$CASE_DIR/.twc-lab/state.env.new"
mv "$CASE_DIR/.twc-lab/state.env.new" "$CASE_DIR/.twc-lab/state.env"
expect_ok "legacy subnet state remains compatible" run_script deploy.sh CONFIRM=1
if grep -q '^PUBLIC_SUBNET_IDS=subnet-a,subnet-b$' "$CASE_DIR/.twc-lab/state.env" && ! grep -q '^SUBNET_IDS=' "$CASE_DIR/.twc-lab/state.env"; then record "legacy subnet state migrates on write" pass; else record "legacy subnet state migrates on write" fail; fi

new_case
expect_fail "conflicting public and legacy subnet inputs fail closed" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 PUBLIC_SUBNET_IDS=subnet-a,subnet-b SUBNET_IDS=subnet-x,subnet-y
assert_no_call "subnet alias conflict is rejected before AWS" "aws "

new_case
expect_fail "failure demo rejects services outside allowlist" run_script demo-failure.sh SERVICE=postgres CONFIRM=1
assert_no_call "invalid failure service does not touch Kubernetes" "kubectl "

new_case
write_state managed
expect_fail "managed destroy requires interactive confirmation" run_script destroy.sh
if grep -Fq 'Account: 111122223333' "$TEST_ROOT/err" &&
   grep -Fq 'Region: us-east-2' "$TEST_ROOT/err" &&
   grep -Fq 'Cluster: twc-lab' "$TEST_ROOT/err" &&
   grep -Fq 'Network mode: managed' "$TEST_ROOT/err" &&
   grep -Fq 'VPC: vpc-123456' "$TEST_ROOT/err" &&
   grep -Fq 'Network ownership: lab-managed' "$TEST_ROOT/err"; then
  record "managed destroy summarizes its exact target before confirmation" pass
else
  record "managed destroy summarizes its exact target before confirmation" fail
fi
assert_no_call "unconfirmed managed destroy does not delete the cluster" "eksctl delete cluster"
assert_no_call "unconfirmed managed destroy does not uninstall Helm releases" "helm uninstall"
assert_no_call "unconfirmed managed destroy does not delete Kubernetes resources" "kubectl delete"
assert_no_call "unconfirmed managed destroy does not scale Kubernetes resources" "kubectl scale"
assert_no_call "unconfirmed managed destroy does not delete CloudFormation stacks" "aws cloudformation delete-stack"
assert_no_call "unconfirmed managed destroy does not deploy CloudFormation stacks" "aws cloudformation deploy"

new_case
write_state existing
expect_fail "existing-network destroy requires interactive confirmation" run_script destroy.sh
if grep -Fq 'Account: 111122223333' "$TEST_ROOT/err" &&
   grep -Fq 'Region: us-east-2' "$TEST_ROOT/err" &&
   grep -Fq 'Cluster: twc-lab' "$TEST_ROOT/err" &&
   grep -Fq 'Network mode: existing' "$TEST_ROOT/err" &&
   grep -Fq 'VPC: vpc-123456' "$TEST_ROOT/err" &&
   grep -Fq 'Network ownership: externally-owned' "$TEST_ROOT/err"; then
  record "existing-network destroy summarizes preserved ownership before confirmation" pass
else
  record "existing-network destroy summarizes preserved ownership before confirmation" fail
fi
assert_no_call "unconfirmed existing-network destroy does not delete the cluster" "eksctl delete cluster"
assert_no_call "unconfirmed existing-network destroy does not uninstall Helm releases" "helm uninstall"
assert_no_call "unconfirmed existing-network destroy does not delete Kubernetes resources" "kubectl delete"
assert_no_call "unconfirmed existing-network destroy does not scale Kubernetes resources" "kubectl scale"
assert_no_call "unconfirmed existing-network destroy does not delete CloudFormation stacks" "aws cloudformation delete-stack"
assert_no_call "unconfirmed existing-network destroy does not deploy CloudFormation stacks" "aws cloudformation deploy"

new_case
write_state managed
expect_fail "destroy rejects an account mismatch" run_script destroy.sh CONFIRM=1 FAKE_ACCOUNT=999900001111
assert_no_call "account mismatch prevents cluster deletion" "eksctl delete cluster"

new_case
write_state managed
expect_fail "deploy rejects state from another account" run_script deploy.sh CONFIRM=1 FAKE_ACCOUNT=999900001111
assert_no_call "state account mismatch prevents stack mutation" "aws cloudformation deploy"

new_case
write_state managed
expect_fail "deploy stops when tracked cluster lookup is unauthorized" run_script deploy.sh CONFIRM=1 FAKE_CLUSTER_ERROR=AccessDeniedException
assert_no_call "cluster lookup error prevents eksctl creation" "eksctl create cluster"

new_case
write_state managed
sed 's/^STACK_NAME=.*/STACK_NAME=unrelated-production-stack/' "$CASE_DIR/.twc-lab/state.env" >"$CASE_DIR/.twc-lab/state.env.new"
mv "$CASE_DIR/.twc-lab/state.env.new" "$CASE_DIR/.twc-lab/state.env"
expect_fail "destroy rejects an out-of-scope managed stack" run_script destroy.sh CONFIRM=1
assert_no_call "out-of-scope stack is never deleted" "aws cloudformation delete-stack"

new_case
write_state managed
# shellcheck disable=SC2016 # The literal command substitution tests that state is never evaluated.
printf 'EVIL=$(touch %s)\n' "$CASE_DIR/executed" >>"$CASE_DIR/.twc-lab/state.env"
expect_fail "state parser rejects unknown keys" run_script status.sh
if [[ ! -e "$CASE_DIR/executed" ]]; then record "state parser never executes values" pass; else record "state parser never executes values" fail; fi

new_case
write_state managed
expect_ok "status emits JSON with live operational layers" run_script status.sh JSON=1 FAKE_NLB_HOST=live.example.test
if ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$TEST_ROOT/out" && grep -Fq '"phase":"DEPLOYED"' "$TEST_ROOT/out" && grep -Fq '"publicSubnetIds":"subnet-a,subnet-b"' "$TEST_ROOT/out" && grep -Fq '"pendingVolumeIds":""' "$TEST_ROOT/out" && grep -Fq '"helmReleases":' "$TEST_ROOT/out" && grep -Fq '"pods":' "$TEST_ROOT/out" && grep -Fq '"pvcs":' "$TEST_ROOT/out" && grep -Fq '"ingressHostname":"live.example.test"' "$TEST_ROOT/out" && grep -Fq '"simulatorHealth":' "$TEST_ROOT/out" && grep -Fq '"layerExplanation":' "$TEST_ROOT/out"; then record "JSON status includes every required operational layer" pass; else record "JSON status includes every required operational layer" fail; fi
expect_ok "status emits a human operational summary" run_script status.sh FAKE_NLB_HOST=live.example.test
if grep -Fq 'Phase:          DEPLOYED' "$TEST_ROOT/out" && grep -Fq 'Public subnets: subnet-a,subnet-b' "$TEST_ROOT/out" && grep -Fq 'Pending volumes: none' "$TEST_ROOT/out" && grep -Fq 'Helm releases:' "$TEST_ROOT/out" && grep -Fq 'Pods:' "$TEST_ROOT/out" && grep -Fq 'PVCs:' "$TEST_ROOT/out" && grep -Fq 'Ingress:' "$TEST_ROOT/out" && grep -Fq 'Simulator health:' "$TEST_ROOT/out" && grep -Fq 'Layers:' "$TEST_ROOT/out"; then record "human status includes every required operational layer" pass; else record "human status includes every required operational layer" fail; fi

new_case
write_state managed
expect_ok "status survives an unauthorized cluster lookup" run_script status.sh JSON=1 FAKE_CLUSTER_ERROR=AccessDeniedException
if grep -Fq '"clusterStatus":"UNKNOWN"' "$TEST_ROOT/out"; then record "status does not misreport lookup errors as absent" pass; else record "status does not misreport lookup errors as absent" fail; fi

new_case
write_state managed
expect_ok "allowed failure can be demonstrated" run_script demo-failure.sh SERVICE=artemis CONFIRM=1
if grep -Fq 'kubectl scale statefulset twc-lab-artemis --replicas=0' "$CALLS"; then record "failure scales the exact StatefulSet to zero" pass; else record "failure scales the exact StatefulSet to zero" fail; fi
expect_ok "recorded failure can be restored" run_script demo-restore.sh CONFIRM=1
if grep -Fq 'kubectl scale statefulset twc-lab-artemis --replicas=1' "$CALLS" && grep -q '^FAILED_SERVICE=$' "$CASE_DIR/.twc-lab/state.env"; then record "restore scales to one and clears state" pass; else record "restore scales to one and clears state" fail; fi

new_case
write_state managed
expect_fail "failed rollout still reports the scaled service" run_script demo-failure.sh SERVICE=artemis CONFIRM=1 FAKE_ROLLOUT_FAIL=1
if grep -Fq 'FAILED_SERVICE=artemis' "$CASE_DIR/.twc-lab/state.env"; then record "failure state is recorded before rollout wait" pass; else record "failure state is recorded before rollout wait" fail; fi

new_case
write_state managed
expect_ok "restore is harmless when no failure is recorded" run_script demo-restore.sh PATH="$NO_KUBE_BIN"
assert_no_call "no-op restore does not scale Kubernetes" "kubectl scale"

new_case
write_state managed
expect_ok "managed destroy succeeds" run_script destroy.sh CONFIRM=1
if grep -Fq 'helm uninstall twc-lab --namespace twc-lab --ignore-not-found' "$CALLS" && grep -Fq 'helm uninstall ingress-nginx --namespace ingress-nginx --ignore-not-found' "$CALLS"; then record "destroy tolerates already-removed Helm releases" pass; else record "destroy tolerates already-removed Helm releases" fail; fi
assert_order "destroy selects the recorded cluster before Helm mutation" "aws eks update-kubeconfig" "helm uninstall twc-lab"
assert_order "NLB removal precedes cluster deletion" "kubectl delete service ingress-nginx-controller" "eksctl delete cluster"
assert_order "label-scoped PVC cleanup precedes cluster deletion" "kubectl delete persistentvolumeclaims --namespace twc-lab --selector app.kubernetes.io/instance=twc-lab" "eksctl delete cluster"
assert_order "cluster deletion precedes VPC deletion" "eksctl delete cluster" "aws cloudformation delete-stack"

new_case
write_state managed
expect_ok "destroy waits through bound PV and EBS cleanup" run_script destroy.sh CONFIRM=1 FAKE_PVC_PRESENT=1
assert_order "PV lookup precedes cluster deletion" "kubectl get persistentvolume pv-lab123" "eksctl delete cluster"
assert_order "EBS deletion check precedes cluster deletion" "aws ec2 describe-volumes --region us-east-2 --volume-ids vol-pvc123" "eksctl delete cluster"

new_case
write_state managed
expect_fail "storage lookup failure blocks cluster cleanup" run_script destroy.sh CONFIRM=1 FAKE_PVC_PRESENT=1 FAKE_VOLUME_LOOKUP_ERROR=1
if [[ -f "$CASE_DIR/.twc-lab/state.env" ]]; then record "storage verification failure preserves state" pass; else record "storage verification failure preserves state" fail; fi
if grep -q '^PENDING_VOLUME_IDS=vol-pvc123$' "$CASE_DIR/.twc-lab/state.env"; then record "failed storage wait persists exact pending volume" pass; else record "failed storage wait persists exact pending volume" fail; fi
assert_no_call "storage verification failure prevents cluster deletion" "eksctl delete cluster"
assert_no_call "storage verification failure preserves managed VPC" "aws cloudformation delete-stack"
: >"$CALLS"
expect_ok "storage cleanup retry consumes persisted pending volume" run_script destroy.sh CONFIRM=1
assert_order "retry verifies pending volume before cluster deletion" "aws ec2 describe-volumes --region us-east-2 --volume-ids vol-pvc123" "eksctl delete cluster"

new_case
write_state managed
rm -f "$FAKE_CLUSTER_MARK"
expect_ok "managed cleanup resumes after cluster is already absent" run_script destroy.sh CONFIRM=1
assert_no_call "absent cluster skips Kubernetes mutation" "kubectl "
assert_no_call "absent cluster skips eksctl deletion" "eksctl delete cluster"
if grep -Fq 'aws cloudformation delete-stack' "$CALLS"; then record "absent cluster still permits managed VPC cleanup" pass; else record "absent cluster still permits managed VPC cleanup" fail; fi

new_case
write_state managed
sed 's/^NLB_HOSTNAME=.*/NLB_HOSTNAME=/' "$CASE_DIR/.twc-lab/state.env" >"$CASE_DIR/.twc-lab/state.env.new"
mv "$CASE_DIR/.twc-lab/state.env.new" "$CASE_DIR/.twc-lab/state.env"
expect_ok "destroy discovers an unpersisted ingress hostname" run_script destroy.sh CONFIRM=1 FAKE_NLB_HOST=discovered.example.test
if grep -Fq "DNSName=='discovered.example.test'" "$CALLS"; then record "destroy waits for the discovered ingress load balancer" pass; else record "destroy waits for the discovered ingress load balancer" fail; fi

new_case
write_state managed
sed 's/^NLB_HOSTNAME=.*/NLB_HOSTNAME=/' "$CASE_DIR/.twc-lab/state.env" >"$CASE_DIR/.twc-lab/state.env.new"
mv "$CASE_DIR/.twc-lab/state.env.new" "$CASE_DIR/.twc-lab/state.env"
expect_fail "destroy preserves a newly discovered hostname on cleanup failure" run_script destroy.sh CONFIRM=1 FAKE_NLB_HOST=retry.example.test FAKE_HELM_UNINSTALL_FAIL=1
if grep -Fq 'NLB_HOSTNAME=retry.example.test' "$CASE_DIR/.twc-lab/state.env"; then record "retry state retains the discovered load balancer" pass; else record "retry state retains the discovered load balancer" fail; fi
assert_no_call "failed workload uninstall does not delete PVCs" "kubectl delete persistentvolumeclaims"

new_case
write_state existing
expect_ok "existing network destroy succeeds" run_script destroy.sh CONFIRM=1
assert_no_call "existing network destroy preserves CloudFormation" "aws cloudformation delete-stack"

new_case
write_state managed
expect_fail "cleanup reports cluster deletion failure" run_script destroy.sh CONFIRM=1 FAKE_CLUSTER_DELETE_FAIL=1
if [[ -f "$CASE_DIR/.twc-lab/state.env" ]]; then record "state survives partial cleanup failure" pass; else record "state survives partial cleanup failure" fail; fi
if grep -q '^PHASE=CLUSTER_DELETING$' "$CASE_DIR/.twc-lab/state.env"; then record "completed Kubernetes cleanup records cluster deletion phase" pass; else record "completed Kubernetes cleanup records cluster deletion phase" fail; fi
: >"$CALLS"
expect_ok "cluster deletion retry survives unavailable Kubernetes API" run_script destroy.sh CONFIRM=1 FAKE_KUBE_API_UNAVAILABLE=1
assert_no_call "cluster deletion retry bypasses completed Kubernetes cleanup" "kubectl "
assert_no_call "cluster deletion retry bypasses completed Helm cleanup" "helm "

new_case
write_state managed
expect_fail "Auto Mode ELB residual blocks cleanup" run_script destroy.sh CONFIRM=1 FAKE_ALL_ELB_ARNS=arn:aws:elasticloadbalancing:us-east-2:111122223333:loadbalancer/net/auto/123 FAKE_RESIDUAL_ELBS=arn:aws:elasticloadbalancing:us-east-2:111122223333:loadbalancer/net/auto/123
if grep -Fq "eks:eks-cluster-name" "$CALLS" && [[ -f "$CASE_DIR/.twc-lab/state.env" ]]; then record "Auto Mode ELB ARN is detected and state preserved" pass; else record "Auto Mode ELB ARN is detected and state preserved" fail; fi
assert_no_call "ELB residual preserves managed VPC stack" "aws cloudformation delete-stack"

new_case
write_state managed
expect_fail "Auto Mode EBS residual blocks cleanup" run_script destroy.sh CONFIRM=1 FAKE_RESIDUAL_VOLUMES=vol-auto123
if grep -Fq "Name=tag:eks:eks-cluster-name,Values=twc-lab" "$CALLS" && [[ -f "$CASE_DIR/.twc-lab/state.env" ]]; then record "Auto Mode EBS volume is detected and state preserved" pass; else record "Auto Mode EBS volume is detected and state preserved" fail; fi
assert_no_call "EBS residual preserves managed VPC stack" "aws cloudformation delete-stack"

new_case
write_state managed
expect_fail "NLB lookup error blocks cleanup" run_script destroy.sh CONFIRM=1 FAKE_NLB_LOOKUP_ERROR=1
if [[ -f "$CASE_DIR/.twc-lab/state.env" ]]; then record "NLB lookup error preserves state" pass; else record "NLB lookup error preserves state" fail; fi
if grep -q '^PHASE=DEPLOYED$' "$CASE_DIR/.twc-lab/state.env"; then record "incomplete cleanup cannot enter cluster deletion phase" pass; else record "incomplete cleanup cannot enter cluster deletion phase" fail; fi
assert_no_call "NLB lookup error prevents cluster deletion" "eksctl delete cluster"
assert_no_call "NLB lookup error preserves managed VPC stack" "aws cloudformation delete-stack"

new_case
expect_fail "zero NLB timeout is rejected" run_script deploy.sh CONFIRM=1 NLB_WAIT_SECONDS=0
assert_no_call "invalid timeout is rejected before AWS" "aws "

new_case
expect_fail "failed initial stack creation preserves deployment identity" run_script deploy.sh CONFIRM=1 FAKE_STACK_DEPLOY_FAIL=1
if grep -q '^DEPLOYMENT_ID=[a-f0-9]\{32\}$' "$CASE_DIR/.twc-lab/state.env"; then record "partial deploy has scoped recovery state" pass; else record "partial deploy has scoped recovery state" fail; fi
if grep -q '^VPC_STACK_ID=arn:aws:cloudformation:' "$CASE_DIR/.twc-lab/state.env"; then record "failed stack creation records exact stack identity" pass; else record "failed stack creation records exact stack identity" fail; fi

new_case
expect_ok "atomic cluster tagging does not need tag-resource" run_script deploy.sh CONFIRM=1 FAKE_CLUSTER_TAG_FAIL=1
if grep -q '^CLUSTER_ARN=arn:aws:eks:' "$CASE_DIR/.twc-lab/state.env"; then record "atomic cluster deploy records exact ARN" pass; else record "atomic cluster deploy records exact ARN" fail; fi
assert_no_call "successful cluster creation avoids tag-resource fallback" "aws eks tag-resource"

new_case
expect_fail "nonzero eksctl creation recovers a matching tagged cluster" run_script deploy.sh CONFIRM=1 FAKE_CREATE_CLUSTER_FAIL=1
if grep -q '^CLUSTER_ARN=arn:aws:eks:' "$CASE_DIR/.twc-lab/state.env"; then record "failed create persists recovered cluster ARN" pass; else record "failed create persists recovered cluster ARN" fail; fi
assert_no_call "atomic cluster tag needs no tag-resource fallback" "aws eks tag-resource"
: >"$CALLS"
expect_ok "destroy succeeds after failed-create ARN recovery" run_script destroy.sh CONFIRM=1
assert_no_call "pre-Helm recovery destroy bypasses Kubernetes API" "kubectl "

new_case
expect_fail "missing deployment tag refuses cluster adoption" run_script deploy.sh CONFIRM=1 FAKE_CLUSTER_DEPLOYMENT_ID=None
assert_no_call "missing tag is never force-adopted" "aws eks tag-resource"

new_case
expect_fail "wrong deployment tag refuses cluster adoption" run_script deploy.sh CONFIRM=1 FAKE_CLUSTER_DEPLOYMENT_ID=ffffffffffffffffffffffffffffffff
assert_no_call "wrong tag is never force-adopted" "aws eks tag-resource"

new_case
expect_ok "deploy creates state for rollback detection" run_script deploy.sh CONFIRM=1
: >"$CALLS"
expect_fail "rollback-complete stack is not blindly reused" run_script deploy.sh CONFIRM=1 FAKE_STACK_STATUS=ROLLBACK_COMPLETE
assert_no_call "rollback stack prevents Helm mutation" "helm upgrade --install"

new_case
expect_ok "deploy prepares cluster identity" run_script deploy.sh CONFIRM=1
: >"$CALLS"
expect_fail "destroy rejects a same-name replacement cluster" run_script destroy.sh CONFIRM=1 FAKE_CLUSTER_ARN=arn:aws:eks:us-east-2:111122223333:cluster/replaced
assert_no_call "replacement cluster is never mutated" "helm uninstall twc-lab"

new_case
expect_ok "deploy records stack identity" run_script deploy.sh CONFIRM=1
: >"$CALLS"
expect_fail "destroy rejects a replaced same-name stack" run_script destroy.sh CONFIRM=1 FAKE_STACK_ID=arn:aws:cloudformation:us-east-2:111122223333:stack/twc-lab-vpc/replaced
assert_no_call "replacement stack is never deleted" "aws cloudformation delete-stack"

new_case
write_state managed
rm -f "$FAKE_CLUSTER_MARK" "$FAKE_STACK_MARK"
expect_ok "destroy treats a precisely absent managed stack as success" run_script destroy.sh CONFIRM=1

new_case
write_state managed
sed 's/^VPC_STACK_ID=.*/VPC_STACK_ID=/' "$CASE_DIR/.twc-lab/state.env" >"$CASE_DIR/.twc-lab/state.env.new"
mv "$CASE_DIR/.twc-lab/state.env.new" "$CASE_DIR/.twc-lab/state.env"
expect_ok "destroy recovers a missing exact stack ID from matching identity" run_script destroy.sh CONFIRM=1

new_case
write_state managed
rm -f "$FAKE_CLUSTER_MARK"
sed 's/^VPC_STACK_ID=.*/VPC_STACK_ID=/' "$CASE_DIR/.twc-lab/state.env" >"$CASE_DIR/.twc-lab/state.env.new"
mv "$CASE_DIR/.twc-lab/state.env.new" "$CASE_DIR/.twc-lab/state.env"
expect_fail "stack recovery rejects the wrong deployment identity" run_script destroy.sh CONFIRM=1 FAKE_STACK_DEPLOYMENT_ID=ffffffffffffffffffffffffffffffff
assert_no_call "wrong stack recovery identity is never deleted" "aws cloudformation delete-stack"

new_case
write_state managed
rm -f "$FAKE_CLUSTER_MARK"
expect_ok "destroy resumes an in-progress stack deletion" run_script destroy.sh CONFIRM=1 FAKE_STACK_STATUS=DELETE_IN_PROGRESS FAKE_DELETE_STACK_FAIL=1
assert_no_call "in-progress stack is not deleted twice" "aws cloudformation delete-stack"

printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
