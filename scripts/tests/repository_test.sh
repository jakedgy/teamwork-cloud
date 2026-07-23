#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
former_region='us-east''-2'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if matches=$(git -C "$ROOT" grep -n "$former_region" -- .); then
  printf '%s\n' "$matches" >&2
  fail "tracked files still reference the former default region"
else
  status=$?
  (( status == 1 )) || fail "unable to inspect tracked files for former default region"
fi

for script in preflight.sh render-cluster-config.sh deploy.sh; do
  grep -Eq '^[[:space:]]*AWS_REGION=\$\{AWS_REGION:-us-east-1\}[[:space:]]*$' "$ROOT/scripts/$script" ||
    fail "$script does not default AWS_REGION to us-east-1"
done

grep -Eq '^awsRegion: us-east-1$' "$ROOT/charts/twc-lab/values.yaml" ||
  fail "chart values do not default to us-east-1"

for required_file in \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  LICENSES/gocql-LICENSE.txt \
  LICENSES/gocql-NOTICE.txt \
  LICENSES/golang-snappy-LICENSE.txt \
  LICENSES/go-hostpool-LICENSE.txt \
  LICENSES/inf-LICENSE.txt; do
  [[ -s "$ROOT/$required_file" ]] || fail "$required_file is missing or empty"
done

grep -Fq 'Zero-Clause BSD' "$ROOT/LICENSE" ||
  fail "LICENSE does not identify the Zero-Clause BSD license"

compiled_modules=$(cd "$ROOT" && go list -deps \
  -f '{{with .Module}}{{if ne .Path "github.com/jakedgy/teamwork-cloud"}}{{.Path}} {{.Version}}{{end}}{{end}}' \
  ./cmd/twc-lab | sed '/^$/d' | sort -u)
expected_modules=$(printf '%s\n' \
  'github.com/gocql/gocql v1.7.0' \
  'github.com/golang/snappy v0.0.3' \
  'github.com/hailocab/go-hostpool v0.0.0-20160125115350-e80d13ce29ed' \
  'gopkg.in/inf.v0 v0.9.1')
[[ "$compiled_modules" == "$expected_modules" ]] || {
  printf 'resolved compiled modules:\n%s\n' "$compiled_modules" >&2
  fail "compiled dependency inventory changed; update notices deliberately"
}

module_cache=$(go env GOMODCACHE)
while IFS='|' read -r repository_file module_file; do
  cmp -s "$ROOT/$repository_file" "$module_cache/$module_file" ||
    fail "$repository_file does not match the resolved module license artifact"
done <<'LICENSE_FILES'
LICENSES/gocql-LICENSE.txt|github.com/gocql/gocql@v1.7.0/LICENSE
LICENSES/gocql-NOTICE.txt|github.com/gocql/gocql@v1.7.0/NOTICE
LICENSES/golang-snappy-LICENSE.txt|github.com/golang/snappy@v0.0.3/LICENSE
LICENSES/go-hostpool-LICENSE.txt|github.com/hailocab/go-hostpool@v0.0.0-20160125115350-e80d13ce29ed/LICENSE
LICENSES/inf-LICENSE.txt|gopkg.in/inf.v0@v0.9.1/LICENSE
LICENSE_FILES

for component in \
  'github.com/gocql/gocql v1.7.0' \
  'github.com/golang/snappy v0.0.3' \
  'github.com/hailocab/go-hostpool v0.0.0-20160125115350-e80d13ce29ed' \
  'gopkg.in/inf.v0 v0.9.1' \
  'cassandra:4.1.4' \
  'zookeeper:3.9.2' \
  'apache/activemq-artemis:2.32.0' \
  'ingress-nginx chart 4.13.3' \
  'gcr.io/distroless/static-debian12'; do
  grep -Fq "$component" "$ROOT/THIRD_PARTY_NOTICES.md" ||
    fail "THIRD_PARTY_NOTICES.md does not list $component"
done

printf 'repository policy checks passed\n'
