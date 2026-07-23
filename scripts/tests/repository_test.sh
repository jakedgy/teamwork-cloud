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

expected_license=$(cat <<'LICENSE'
Zero-Clause BSD

Copyright (C) 2026 teamwork-cloud contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
LICENSE
)
cmp -s "$ROOT/LICENSE" <(printf '%s\n' "$expected_license") ||
  fail "LICENSE does not match the approved Zero-Clause BSD text"

replacements=$(cd "$ROOT" && go list -m \
  -f '{{if .Replace}}{{.Path}} => {{.Replace.Path}} {{.Replace.Version}}{{end}}' \
  all | sed '/^$/d')
[[ -z "$replacements" ]] || {
  printf 'resolved Go module replacements:\n%s\n' "$replacements" >&2
  fail "Go module replacements require a deliberate license review"
}

expected_modules=$(printf '%s\n' \
  'github.com/gocql/gocql v1.7.0' \
  'github.com/golang/snappy v0.0.3' \
  'github.com/hailocab/go-hostpool v0.0.0-20160125115350-e80d13ce29ed' \
  'gopkg.in/inf.v0 v0.9.1')
for arch in amd64 arm64; do
  printf 'checking compiled dependency inventory for linux/%s\n' "$arch"
  compiled_modules=$(cd "$ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go list -deps \
    -f '{{with .Module}}{{if ne .Path "github.com/jakedgy/teamwork-cloud"}}{{.Path}} {{.Version}}{{end}}{{end}}' \
    ./cmd/twc-lab | sed '/^$/d' | sort -u)
  [[ "$compiled_modules" == "$expected_modules" ]] || {
    printf 'resolved compiled modules for linux/%s:\n%s\n' "$arch" "$compiled_modules" >&2
    fail "compiled dependency inventory changed for linux/$arch; update notices deliberately"
  }
done

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

grep -Fqx 'AWS CLI, eksctl, Kubernetes, Helm, Docker, Make, Bash, OpenSSL, jq, and GitHub Actions are acquired separately under their own terms.' \
  "$ROOT/THIRD_PARTY_NOTICES.md" ||
  fail "THIRD_PARTY_NOTICES.md does not contain the approved separately acquired tools notice"

for compiled_row in \
  '| `github.com/gocql/gocql v1.7.0` | Apache-2.0 ([LICENSE](LICENSES/gocql-LICENSE.txt), [NOTICE](LICENSES/gocql-NOTICE.txt)) |' \
  '| `github.com/golang/snappy v0.0.3` | BSD-3-Clause ([LICENSE](LICENSES/golang-snappy-LICENSE.txt)) |' \
  '| `github.com/hailocab/go-hostpool v0.0.0-20160125115350-e80d13ce29ed` | MIT ([LICENSE](LICENSES/go-hostpool-LICENSE.txt)) |' \
  '| `gopkg.in/inf.v0 v0.9.1` | BSD-3-Clause ([LICENSE](LICENSES/inf-LICENSE.txt)) |'; do
  grep -Fqx "$compiled_row" "$ROOT/THIRD_PARTY_NOTICES.md" ||
    fail "THIRD_PARTY_NOTICES.md is missing approved compiled component row: $compiled_row"
done

for external_row in \
  '| `cassandra:4.1.4` | [Apache Cassandra](https://github.com/apache/cassandra) | Apache-2.0 plus image notices |' \
  '| `zookeeper:3.9.2` | [Apache ZooKeeper](https://github.com/apache/zookeeper) | Apache-2.0 plus image notices |' \
  '| `apache/activemq-artemis:2.32.0` | [Apache ActiveMQ Artemis](https://github.com/apache/activemq-artemis) | Apache-2.0 plus image notices |' \
  '| `ingress-nginx chart 4.13.3` | [ingress-nginx](https://github.com/kubernetes/ingress-nginx) | Apache-2.0 plus chart/image dependencies |' \
  '| `gcr.io/distroless/static-debian12` pinned by digest | [Distroless](https://github.com/GoogleContainerTools/distroless) | Apache-2.0 project code plus included Debian-material licenses |' \
  '| `golang:1.26.5-alpine` pinned by digest, build stage only | [Docker Official Image for Go](https://github.com/docker-library/golang) | Upstream Go/Alpine/image terms; not the final runtime base |'; do
  grep -Fqx "$external_row" "$ROOT/THIRD_PARTY_NOTICES.md" ||
    fail "THIRD_PARTY_NOTICES.md is missing approved external component row: $external_row"
done

printf 'repository policy checks passed\n'
