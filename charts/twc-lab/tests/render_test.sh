#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
missing_password_output="$(mktemp)"
mutated="$(mktemp)"
trap 'rm -f "$rendered" "$missing_password_output" "$mutated"' EXIT

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

resource_exists() {
  local manifest="$1"
  local expected_kind="$2"
  local expected_name="$3"
  local expected_type="${4:-}"

  awk \
    -v expected_kind="$expected_kind" \
    -v expected_name="$expected_name" \
    -v expected_type="$expected_type" '
      function matches_resource() {
        return kind == expected_kind && name == expected_name && \
          (expected_type == "" || type == expected_type)
      }
      function finish_document() {
        if (matches_resource()) {
          found = 1
        }
        kind = ""
        name = ""
        type = ""
        in_metadata = 0
        in_spec = 0
      }
      /^---[[:space:]]*$/ {
        finish_document()
        next
      }
      /^kind:[[:space:]]*/ {
        kind = $0
        sub(/^kind:[[:space:]]*/, "", kind)
        next
      }
      /^metadata:[[:space:]]*$/ {
        in_metadata = 1
        in_spec = 0
        next
      }
      /^spec:[[:space:]]*$/ {
        in_metadata = 0
        in_spec = 1
        next
      }
      /^[^[:space:]]/ {
        in_metadata = 0
        in_spec = 0
      }
      in_metadata && /^  name:[[:space:]]*/ {
        name = $0
        sub(/^  name:[[:space:]]*/, "", name)
        next
      }
      in_spec && /^  type:[[:space:]]*/ {
        type = $0
        sub(/^  type:[[:space:]]*/, "", type)
      }
      END {
        finish_document()
        exit !found
      }
    ' "$manifest"
}

assert_resource() {
  local manifest="$1"
  local kind="$2"
  local name="$3"
  local type="${4:-}"
  local description="$5"

  resource_exists "$manifest" "$kind" "$name" "$type" || fail "$description"
}

helm lint "$chart_dir" --set-string secrets.artemisPassword=test-password
helm template twc-lab "$chart_dir" \
  --set-string secrets.artemisPassword=test-password >"$rendered"

assert_count 3 '^kind: StatefulSet$' 'render exactly three StatefulSets'
assert_resource "$rendered" StatefulSet twc-lab-cassandra '' 'render cassandra StatefulSet'
assert_resource "$rendered" StatefulSet twc-lab-zookeeper '' 'render zookeeper StatefulSet'
assert_resource "$rendered" StatefulSet twc-lab-artemis '' 'render artemis StatefulSet'
assert_count 1 '^kind: Deployment$' 'render exactly one Deployment'
assert_resource "$rendered" Deployment twc-lab-simulator '' 'render simulator Deployment'
assert_resource "$rendered" Service twc-lab-simulator ClusterIP \
  'render simulator ClusterIP Service'

sed 's/^kind: StatefulSet$/kind: DaemonSet/' "$rendered" >"$mutated"
if resource_exists "$mutated" StatefulSet twc-lab-cassandra; then
  fail 'StatefulSet assertion accepted a matching name from another document'
fi
sed 's/^kind: Deployment$/kind: ReplicaSet/' "$rendered" >"$mutated"
if resource_exists "$mutated" Deployment twc-lab-simulator; then
  fail 'Deployment assertion accepted the simulator Service document'
fi
sed 's/^kind: Service$/kind: ConfigMap/' "$rendered" >"$mutated"
if resource_exists "$mutated" Service twc-lab-simulator ClusterIP; then
  fail 'Service assertion accepted the simulator Deployment document'
fi
sed 's/^  type: ClusterIP$/  type: NodePort/' "$rendered" >"$mutated"
if resource_exists "$mutated" Service twc-lab-simulator ClusterIP; then
  fail 'simulator Service assertion accepted a non-ClusterIP type'
fi

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
