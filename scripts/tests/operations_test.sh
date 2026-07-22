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
    printf '%s\n' ACTIVE
    ;;
  "ec2 describe-vpcs") printf '%s\n' "${FAKE_VPCS:-vpc-123456}" ;;
  "ec2 describe-subnets")
    if [[ "$*" == *"AvailabilityZone,SubnetId"* ]]; then
      printf '%b\n' "${FAKE_AZ_ROWS:-us-east-2a\tsubnet-a\nus-east-2b\tsubnet-b}"
    else
      [[ "$*" == *'join(`\t`'* ]] || exit 2
      printf '%b\n' "${FAKE_SUBNET_ROWS:-subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1}"
    fi
    ;;
  "ec2 describe-route-tables") printf '%s\n' "${FAKE_DEFAULT_ROUTES:-igw-123456}" ;;
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
      *"OutputKey=='VpcId'"*) printf '%s\n' vpc-managed ;;
      *"OutputKey=='PublicSubnetIds'"*) printf '%s\n' subnet-ma,subnet-mb ;;
      *) printf '%s\n' CREATE_COMPLETE ;;
    esac
    ;;
  "cloudformation deploy")
    [[ "$*" == *"--tags twc-lab:managed=true"* ]] || exit 2
    : >"${FAKE_STACK_MARK}"
    ;;
  "cloudformation delete-stack") ;;
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
  "ec2 describe-volumes") printf '%s\n' "${FAKE_RESIDUAL_VOLUMES:-None}" ;;
  *) ;;
esac
EOF

cat >"$FAKE_BIN/eksctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'eksctl %s\n' "$*" >>"$FAKE_CALLS"
if [[ "${1:-} ${2:-}" == "create cluster" ]]; then
  : >"${FAKE_CLUSTER_MARK}"
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
printf 'helm %s\n' "$*" >>"$FAKE_CALLS"
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
printf 'kubectl %s\n' "$*" >>"$FAKE_CALLS"
case "$*" in
  *"get service ingress-nginx-controller"*) printf '%s\n' "${FAKE_NLB_HOST:-lab.example.test}" ;;
  *"get service twc-lab"*) printf '%s\n' "${FAKE_APP_HOST:-lab.example.test}" ;;
  *"get statefulset"*) printf '%s\n' "${FAKE_REPLICAS:-1}" ;;
  *"get pods"*"--output name"*) printf '%s\n' 'pod/twc-lab-simulator-abc' 'pod/twc-lab-artemis-0' ;;
  *"get persistentvolumeclaims"*"--output name"*) printf '%s\n' 'persistentvolumeclaim/data-twc-lab-artemis-0' ;;
  *"get --raw"*"api/health"*) printf '%s\n' '{"status":"UP","layers":4}' ;;
esac
EOF

cat >"$FAKE_BIN/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '0123456789abcdef0123456789abcdef\n'
EOF
cat >"$FAKE_BIN/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s\n' "$*" >>"$FAKE_CALLS"
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

NO_KUBE_BIN="$TEST_ROOT/no-kube-bin"
mkdir -p "$NO_KUBE_BIN"
ln -s "$(command -v env)" "$NO_KUBE_BIN/env"
ln -s "$(command -v bash)" "$NO_KUBE_BIN/bash"
ln -s "$(command -v dirname)" "$NO_KUBE_BIN/dirname"
ln -s "$FAKE_BIN/aws" "$NO_KUBE_BIN/aws"

export FAKE_CALLS="$CALLS"
export FAKE_STACK_MARK="$TEST_ROOT/stack-created"
export FAKE_CLUSTER_MARK="$TEST_ROOT/cluster-created"
export PATH="$FAKE_BIN:/usr/bin:/bin"

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
}

run_script() {
  local script=$1
  shift
  (cd "$CASE_DIR" && env "$@" "$ROOT/scripts/$script")
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
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

write_state() {
  local mode=$1
  mkdir -p "$CASE_DIR/.twc-lab"
  cat >"$CASE_DIR/.twc-lab/state.env" <<EOF
ACCOUNT_ID=111122223333
AWS_REGION=us-east-2
CLUSTER_NAME=twc-lab
NETWORK_MODE=$mode
VPC_ID=vpc-123456
SUBNET_IDS=subnet-a,subnet-b
STACK_NAME=twc-lab-vpc
FAILED_SERVICE=
NLB_HOSTNAME=lab.example.test
EOF
  chmod 600 "$CASE_DIR/.twc-lab/state.env"
  if [[ $mode == managed ]]; then
    : >"$FAKE_STACK_MARK"
  fi
  : >"$FAKE_CLUSTER_MARK"
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
expect_fail "existing mode requires two subnets" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a

new_case
expect_fail "existing mode requires exactly one matching VPC" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b $'FAKE_VPCS=vpc-123456\tvpc-other'

new_case
expect_fail "existing subnets must span AZs" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\t1\nsubnet-b\tus-east-2a\t32\tTrue\t1'

new_case
expect_fail "existing subnets need sixteen free IPs" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t15\tTrue\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1'

new_case
expect_fail "existing subnets map public IPs" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tFalse\t1\nsubnet-b\tus-east-2b\t32\tTrue\t1'

new_case
expect_fail "existing VPC has an IGW default route" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b FAKE_DEFAULT_ROUTES=None

new_case
expect_fail "existing subnets carry public ELB role tags" run_script preflight.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b $'FAKE_SUBNET_ROWS=subnet-a\tus-east-2a\t32\tTrue\tNone\nsubnet-b\tus-east-2b\t32\tTrue\t1'

new_case
expect_ok "managed deploy succeeds with fake CLIs" run_script deploy.sh CONFIRM=1
assert_order "managed stack precedes cluster creation" "aws cloudformation deploy" "eksctl create cluster"
assert_order "cluster precedes ingress installation" "eksctl create cluster" "helm upgrade --install ingress-nginx"
assert_order "ingress precedes app installation" "helm upgrade --install ingress-nginx" "helm upgrade --install twc-lab"
if [[ $(file_mode "$CASE_DIR/.twc-lab/state.env") == 600 ]]; then record "state file permissions are 0600" pass; else record "state file permissions are 0600" fail; fi
if [[ $(file_mode "$CASE_DIR/.twc-lab/secrets.yaml") == 600 ]]; then record "secrets file permissions are 0600" pass; else record "secrets file permissions are 0600" fail; fi
if grep -Eq '^secrets:$' "$CASE_DIR/.twc-lab/secrets.yaml" && grep -Eq '^  artemisPassword: "[0-9a-f]{32}"$' "$CASE_DIR/.twc-lab/secrets.yaml"; then record "secret uses the chart password key and 32 characters" pass; else record "secret uses the chart password key and 32 characters" fail; fi
if [[ $(cut -d= -f1 "$CASE_DIR/.twc-lab/state.env" | tr '\n' ' ') == "ACCOUNT_ID AWS_REGION CLUSTER_NAME NETWORK_MODE VPC_ID SUBNET_IDS STACK_NAME FAILED_SERVICE NLB_HOSTNAME " ]]; then record "state contains only fixed keys" pass; else record "state contains only fixed keys" fail; fi
if grep -Fq 'nodePools:' "$CASE_DIR/.twc-lab/cluster.yaml" && grep -Fq 'general-purpose' "$CASE_DIR/.twc-lab/cluster.yaml" && grep -Fq 'system' "$CASE_DIR/.twc-lab/cluster.yaml"; then record "renderer enables both Auto Mode pools" pass; else record "renderer enables both Auto Mode pools" fail; fi
if grep -Fq 'http://lab.example.test/webapp' "$TEST_ROOT/out" && grep -Fq 'http://lab.example.test/admin' "$TEST_ROOT/out" && grep -Fq 'http://lab.example.test/admin/license' "$TEST_ROOT/out" && ! grep -Fq '/authentication' "$TEST_ROOT/out"; then record "deploy prints the required three URLs" pass; else record "deploy prints the required three URLs" fail; fi

new_case
expect_fail "preflight rejects an unrelated same-name stack" run_script preflight.sh FAKE_STACK_EXISTS=1 FAKE_STACK_TAG=false

new_case
expect_fail "preflight rejects a managed stack for another cluster" run_script preflight.sh FAKE_STACK_EXISTS=1 FAKE_STACK_CLUSTER=other-cluster

new_case
expect_ok "preflight accepts the tagged intended managed stack" run_script preflight.sh FAKE_STACK_EXISTS=1

new_case
expect_fail "managed deploy stops when stack lookup is unauthorized" run_script deploy.sh CONFIRM=1 FAKE_STACK_ERROR=AccessDeniedException
assert_no_call "stack lookup error prevents CloudFormation mutation" "aws cloudformation deploy"

new_case
expect_ok "existing deploy succeeds with validated network" run_script deploy.sh NETWORK_MODE=existing VPC_ID=vpc-123456 SUBNET_IDS=subnet-a,subnet-b CONFIRM=1
assert_no_call "existing deploy never mutates CloudFormation" "aws cloudformation deploy"
expect_ok "existing deploy reuses its recorded state without repeated flags" run_script deploy.sh CONFIRM=1
assert_no_call "recorded existing mode still never mutates CloudFormation" "aws cloudformation deploy"

new_case
expect_fail "failure demo rejects services outside allowlist" run_script demo-failure.sh SERVICE=postgres CONFIRM=1
assert_no_call "invalid failure service does not touch Kubernetes" "kubectl "

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
printf 'EVIL=$(touch %s)\n' "$CASE_DIR/executed" >>"$CASE_DIR/.twc-lab/state.env"
expect_fail "state parser rejects unknown keys" run_script status.sh
if [[ ! -e "$CASE_DIR/executed" ]]; then record "state parser never executes values" pass; else record "state parser never executes values" fail; fi

new_case
write_state managed
expect_ok "status emits JSON with live operational layers" run_script status.sh JSON=1 FAKE_NLB_HOST=live.example.test
if ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$TEST_ROOT/out" && grep -Fq '"helmReleases":' "$TEST_ROOT/out" && grep -Fq '"pods":' "$TEST_ROOT/out" && grep -Fq '"pvcs":' "$TEST_ROOT/out" && grep -Fq '"ingressHostname":"live.example.test"' "$TEST_ROOT/out" && grep -Fq '"simulatorHealth":' "$TEST_ROOT/out" && grep -Fq '"layerExplanation":' "$TEST_ROOT/out"; then record "JSON status includes every required operational layer" pass; else record "JSON status includes every required operational layer" fail; fi
expect_ok "status emits a human operational summary" run_script status.sh FAKE_NLB_HOST=live.example.test
if grep -Fq 'Helm releases:' "$TEST_ROOT/out" && grep -Fq 'Pods:' "$TEST_ROOT/out" && grep -Fq 'PVCs:' "$TEST_ROOT/out" && grep -Fq 'Ingress:' "$TEST_ROOT/out" && grep -Fq 'Simulator health:' "$TEST_ROOT/out" && grep -Fq 'Layers:' "$TEST_ROOT/out"; then record "human status includes every required operational layer" pass; else record "human status includes every required operational layer" fail; fi

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
expect_ok "restore is harmless when no failure is recorded" run_script demo-restore.sh PATH="$NO_KUBE_BIN"
assert_no_call "no-op restore does not scale Kubernetes" "kubectl scale"

new_case
write_state managed
expect_ok "managed destroy succeeds" run_script destroy.sh CONFIRM=1
if grep -Fq 'helm uninstall twc-lab --namespace twc-lab --ignore-not-found' "$CALLS" && grep -Fq 'helm uninstall ingress-nginx --namespace ingress-nginx --ignore-not-found' "$CALLS"; then record "destroy tolerates already-removed Helm releases" pass; else record "destroy tolerates already-removed Helm releases" fail; fi
assert_order "destroy selects the recorded cluster before Helm mutation" "aws eks update-kubeconfig" "helm uninstall twc-lab"
assert_order "NLB removal precedes cluster deletion" "kubectl delete service ingress-nginx-controller" "eksctl delete cluster"
assert_order "cluster deletion precedes VPC deletion" "eksctl delete cluster" "aws cloudformation delete-stack"

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

new_case
write_state existing
expect_ok "existing network destroy succeeds" run_script destroy.sh CONFIRM=1
assert_no_call "existing network destroy preserves CloudFormation" "aws cloudformation delete-stack"

new_case
write_state managed
expect_fail "cleanup reports cluster deletion failure" run_script destroy.sh CONFIRM=1 FAKE_CLUSTER_DELETE_FAIL=1
if [[ -f "$CASE_DIR/.twc-lab/state.env" ]]; then record "state survives partial cleanup failure" pass; else record "state survives partial cleanup failure" fail; fi

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
assert_no_call "NLB lookup error prevents cluster deletion" "eksctl delete cluster"
assert_no_call "NLB lookup error preserves managed VPC stack" "aws cloudformation delete-stack"

printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
