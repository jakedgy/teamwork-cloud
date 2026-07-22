#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(mktemp)"
missing_password_output="$(mktemp)"
mutated="$(mktemp)"
resource_output="$(mktemp)"
storage_disabled="$(mktemp)"
long_rendered="$(mktemp)"
other_long_rendered="$(mktemp)"
other_secret_rendered="$(mktemp)"
trap 'rm -f "$rendered" "$missing_password_output" "$mutated" "$resource_output" "$storage_disabled" "$long_rendered" "$other_long_rendered" "$other_secret_rendered"' EXIT

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

resource_document() {
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
        if (matches_resource() && !found) {
          printf "%s", document
          found = 1
        }
        document = ""
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
      {
        document = document $0 ORS
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

resource_exists() {
  resource_document "$@" >/dev/null
}

assert_resource() {
  local manifest="$1"
  local kind="$2"
  local name="$3"
  local type="${4:-}"
  local description="$5"

  resource_exists "$manifest" "$kind" "$name" "$type" || fail "$description"
}

assert_resource_contains() {
  local manifest="$1"
  local kind="$2"
  local name="$3"
  local pattern="$4"
  local description="$5"

  resource_document "$manifest" "$kind" "$name" >"$resource_output" || \
    fail "$description (resource not found)"
  grep -Eq -- "$pattern" "$resource_output" || fail "$description"
}

assert_resource_not_contains() {
  local manifest="$1"
  local kind="$2"
  local name="$3"
  local pattern="$4"
  local description="$5"

  resource_document "$manifest" "$kind" "$name" >"$resource_output" || \
    fail "$description (resource not found)"
  if grep -Eq -- "$pattern" "$resource_output"; then
    fail "$description"
  fi
}

assert_resource_count() {
  local manifest="$1"
  local kind="$2"
  local name="$3"
  local expected="$4"
  local pattern="$5"
  local description="$6"
  local actual

  resource_document "$manifest" "$kind" "$name" >"$resource_output" || \
    fail "$description (resource not found)"
  actual="$(grep -Ec -- "$pattern" "$resource_output" || true)"
  [[ "$actual" == "$expected" ]] || \
    fail "$description (expected $expected, got $actual)"
}

assert_ingress_route() {
  local manifest="$1"
  local name="$2"
  local path="$3"
  local path_type="$4"

  resource_document "$manifest" Ingress "$name" >"$resource_output" || \
    fail "ingress ${name} not found while checking ${path}"
  awk -v expected_path="$path" -v expected_type="$path_type" '
    /^          - path:/ {
      path = $0
      sub(/^          - path:[[:space:]]*/, "", path)
      matching_path = path == expected_path
      next
    }
    matching_path && /^            pathType:/ {
      type = $0
      sub(/^            pathType:[[:space:]]*/, "", type)
      if (type == expected_type) found = 1
      matching_path = 0
    }
    END { exit !found }
  ' "$resource_output" || fail "ingress route ${path} is not ${path_type}"
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
assert_resource "$rendered" StorageClass auto-ebs '' 'render chart-managed auto-ebs StorageClass'

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

for path in /webapp /authentication /admin /api/health; do
  assert_ingress_route "$rendered" twc-lab "$path" Prefix
done
assert_ingress_route "$rendered" twc-lab / Exact

assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  '^            - name: ZOO_DATA_LOG_DIR$' 'configure ZooKeeper transaction log directory'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  '^              value: /data/datalog$' 'persist ZooKeeper transaction logs under /data'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  '^            - name: ZOO_4LW_COMMANDS_WHITELIST$' 'enable ZooKeeper ruok command'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  '^              value: ruok$' 'restrict ZooKeeper 4LW commands to ruok'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  '^              mountPath: /data$' 'mount ZooKeeper persistent data directory'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  'ruok' 'probe ZooKeeper with ruok'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  'imok' 'require ZooKeeper imok response'
assert_resource_contains "$rendered" StatefulSet twc-lab-zookeeper \
  'response=\$\(cat <&3\)' 'capture ZooKeeper response without newline-sensitive read'
assert_resource_not_contains "$rendered" StatefulSet twc-lab-zookeeper \
  'tcpSocket:' 'do not use a bare TCP ZooKeeper probe'

assert_resource_contains "$rendered" StatefulSet twc-lab-cassandra \
  'cqlsh' 'probe Cassandra through CQL'
assert_resource_contains "$rendered" StatefulSet twc-lab-cassandra \
  'SELECT release_version FROM system.local' 'use a harmless Cassandra CQL query'
assert_resource_count "$rendered" StatefulSet twc-lab-cassandra 2 \
  '^            timeoutSeconds: 10$' 'allow both Cassandra CQL probes to initialize'
assert_resource_not_contains "$rendered" StatefulSet twc-lab-cassandra \
  'tcpSocket:' 'do not use a bare TCP Cassandra probe'
assert_resource_contains "$rendered" StatefulSet twc-lab-cassandra \
  '^              mountPath: /var/lib/cassandra$' 'mount Cassandra persistent data directory'

assert_resource_contains "$rendered" StatefulSet twc-lab-artemis \
  '/var/lib/artemis-instance/bin/artemis check node' 'probe Artemis with its broker CLI'
assert_resource_contains "$rendered" StatefulSet twc-lab-artemis \
  '\-\-user.*ARTEMIS_USER' 'authenticate Artemis probe with Secret-backed user'
assert_resource_contains "$rendered" StatefulSet twc-lab-artemis \
  '\-\-password.*ARTEMIS_PASSWORD' 'authenticate Artemis probe with Secret-backed password'
assert_resource_not_contains "$rendered" StatefulSet twc-lab-artemis \
  'tcpSocket:' 'do not use a bare TCP Artemis probe'
assert_resource_contains "$rendered" StatefulSet twc-lab-artemis \
  '^              mountPath: /var/lib/artemis-instance$' 'mount Artemis persistent instance directory'
for variable in ARTEMIS_USER ARTEMIS_PASSWORD; do
  assert_resource_contains "$rendered" StatefulSet twc-lab-artemis \
    "^            - name: ${variable}$" "inject ${variable} into Artemis"
done

assert_resource_contains "$rendered" Secret twc-lab-artemis '^immutable: true$' \
  'make demo credentials immutable'
for workload in artemis simulator; do
  kind=StatefulSet
  [[ "$workload" == simulator ]] && kind=Deployment
  assert_resource_contains "$rendered" "$kind" "twc-lab-${workload}" \
    '^        checksum/artemis-secret: [a-f0-9]{64}$' \
    "annotate ${workload} pod template with Secret checksum"
done
helm template twc-lab "$chart_dir" \
  --set-string secrets.artemisPassword=other-test-password >"$other_secret_rendered"
rendered_checksum="$(grep -m1 'checksum/artemis-secret:' "$rendered" | awk '{print $2}')"
other_checksum="$(grep -m1 'checksum/artemis-secret:' "$other_secret_rendered" | awk '{print $2}')"
[[ -n "$rendered_checksum" && -n "$other_checksum" && "$rendered_checksum" != "$other_checksum" ]] || \
  fail 'Secret checksum annotation did not change with credentials'

for resource in 'StatefulSet twc-lab-cassandra' 'StatefulSet twc-lab-zookeeper' \
  'StatefulSet twc-lab-artemis' 'Deployment twc-lab-simulator'; do
  read -r kind name <<<"$resource"
  assert_resource_contains "$rendered" "$kind" "$name" \
    '^      automountServiceAccountToken: false$' "disable token mount for ${name}"
  assert_resource_contains "$rendered" "$kind" "$name" \
    '^          type: RuntimeDefault$' "use RuntimeDefault seccomp for ${name}"
  assert_resource_contains "$rendered" "$kind" "$name" \
    '^  replicas: 1$' "enforce one replica for ${name}"
done

for name in twc-lab-cassandra twc-lab-zookeeper twc-lab-artemis; do
  assert_resource_contains "$rendered" StatefulSet "$name" \
    '^  persistentVolumeClaimRetentionPolicy:$' "configure PVC retention for ${name}"
  assert_resource_contains "$rendered" StatefulSet "$name" \
    '^    whenDeleted: Delete$' "delete ${name} PVC after workload deletion"
  assert_resource_contains "$rendered" StatefulSet "$name" \
    '^    whenScaled: Delete$' "delete ${name} PVC after scale-down"
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
grep -q 'secrets.artemisPassword' "$missing_password_output" || \
  fail 'missing password failure must identify secrets.artemisPassword'

helm template twc-lab "$chart_dir" \
  --set-string secrets.artemisPassword=test-password \
  --set storageClass.create=false \
  --set-string storageClass.name=shared-ebs >"$storage_disabled"
if grep -q '^kind: StorageClass$' "$storage_disabled"; then
  fail 'rendered StorageClass when storageClass.create=false'
fi
[[ "$(grep -Ec '^        storageClassName: shared-ebs$' "$storage_disabled" || true)" == 3 ]] || \
  fail 'existing StorageClass name was not applied to all PVC templates'

for workload in simulator cassandra zookeeper artemis; do
  if helm template twc-lab "$chart_dir" \
    --set-string secrets.artemisPassword=test-password \
    --set "${workload}.replicaCount=2" >"$missing_password_output" 2>&1; then
    fail "schema accepted configurable ${workload} replicas"
  fi
  grep -q 'replicaCount' "$missing_password_output" || \
    fail "${workload} replica validation failure did not identify replicaCount"
done

if helm template twc-lab "$chart_dir" \
  --set-string secrets.artemisPassword=test-password \
  --set simulator.image.pullPolicy=Sometimes >"$missing_password_output" 2>&1; then
  fail 'schema accepted an invalid image pull policy'
fi
grep -q 'pullPolicy' "$missing_password_output" || \
  fail 'pull-policy validation failure did not identify pullPolicy'

if helm template twc-lab "$chart_dir" \
  --set-string secrets.artemisPassword=test-password \
  --set simulator.image.tag=latest >"$missing_password_output" 2>&1; then
  fail 'schema accepted the latest image tag'
fi
grep -q 'simulator.image.tag' "$missing_password_output" || \
  fail 'image-tag validation failure did not identify simulator.image.tag'

max_release='rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr'
other_release='rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrs'
helm template "$max_release" "$chart_dir" \
  --set-string secrets.artemisPassword=test-password >"$long_rendered"
helm template "$other_release" "$chart_dir" \
  --set-string secrets.artemisPassword=test-password >"$other_long_rendered"
awk '
  /^metadata:$/ { in_metadata = 1; next }
  /^[^[:space:]]/ { in_metadata = 0 }
  in_metadata && /^  name:/ {
    name = $0
    sub(/^  name:[[:space:]]*/, "", name)
    if (length(name) > 63) exit 1
  }
' "$long_rendered" || fail 'long release rendered a resource name over 63 characters'
for component in cassandra zookeeper artemis simulator; do
  grep -Eq "^  name: .*-${component}$" "$long_rendered" || \
    fail "long release name dropped ${component} suffix"
done
long_cassandra="$(awk '/^  name: .*\-cassandra$/ { print $2; exit }' "$long_rendered")"
other_cassandra="$(awk '/^  name: .*\-cassandra$/ { print $2; exit }' "$other_long_rendered")"
[[ -n "$long_cassandra" && -n "$other_cassandra" && "$long_cassandra" != "$other_cassandra" ]] || \
  fail 'truncated release names did not produce unique Cassandra names'

grep -q '^    enableHttps: false$' "$chart_dir/../../cluster/ingress-nginx-values.yaml" || \
  fail 'ingress-nginx HTTPS listener was not disabled'

printf 'PASS: chart render contract satisfied\n'
