#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
missing_password_output="$(mktemp)"
trap 'rm -f "$rendered" "$missing_password_output"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1"
  local description="$2"
  grep -Eq -- "$pattern" "$rendered" || fail "$description"
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local description="$3"
  local actual
  actual="$(grep -Ec -- "$pattern" "$rendered" || true)"
  [[ "$actual" == "$expected" ]] || fail "$description (expected $expected, got $actual)"
}

helm lint "$chart_dir" --set-string secrets.artemisPassword=test-password
helm template twc-lab "$chart_dir" \
  --set-string secrets.artemisPassword=test-password >"$rendered"

assert_count 3 '^kind: StatefulSet$' 'render exactly three StatefulSets'
assert_contains '^  name: twc-lab-cassandra$' 'render cassandra StatefulSet'
assert_contains '^  name: twc-lab-zookeeper$' 'render zookeeper StatefulSet'
assert_contains '^  name: twc-lab-artemis$' 'render artemis StatefulSet'
assert_count 1 '^kind: Deployment$' 'render exactly one Deployment'
assert_contains '^  name: twc-lab-simulator$' 'render simulator workload and Service'
assert_contains '^  type: ClusterIP$' 'make simulator Service a ClusterIP'

assert_count 3 '^        storageClassName: auto-ebs$' 'use auto-ebs for every StatefulSet claim'
assert_count 1 '^            storage: 8Gi$' 'request one 8Gi volume'
assert_count 2 '^            storage: 2Gi$' 'request two 2Gi volumes'

for port in 9042 2181 61616 8080; do
  assert_contains "^      port: ${port}$|^        - containerPort: ${port}$" "expose port ${port}"
done

for path in /webapp /authentication /admin; do
  assert_contains "^          - path: ${path}$" "route ingress prefix ${path}"
done

assert_contains '^        runAsNonRoot: true$' 'run simulator as non-root'
assert_contains '^            allowPrivilegeEscalation: false$' 'disable simulator privilege escalation'
assert_contains '^            readOnlyRootFilesystem: true$' 'make simulator root filesystem read-only'
assert_contains '^              drop:$' 'configure dropped Linux capabilities'
assert_contains '^                - ALL$' 'drop every Linux capability'

if grep -Eqi '^(kind: (ClusterRole|ClusterRoleBinding)|.*metallb|.*keda|.*flexnet|[[:space:]]*image:.*vendor|[[:space:]]*image:.*:latest([[:space:]]|$))' "$rendered"; then
  fail 'render includes a forbidden cluster-scoped, autoscaling, licensing, vendor-image, or latest-tag resource'
fi

if helm template twc-lab "$chart_dir" >"$missing_password_output" 2>&1; then
  fail 'render without artemis.password must fail'
fi
grep -q 'secrets.artemisPassword is required' "$missing_password_output" || \
  fail 'missing password failure must explain secrets.artemisPassword is required'

printf 'PASS: chart render contract satisfied\n'
