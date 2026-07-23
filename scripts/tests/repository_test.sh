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
fi

for script in preflight.sh render-cluster-config.sh deploy.sh; do
  grep -Fq 'AWS_REGION=${AWS_REGION:-us-east-1}' "$ROOT/scripts/$script" ||
    fail "$script does not default AWS_REGION to us-east-1"
done

grep -Eq '^awsRegion: us-east-1$' "$ROOT/charts/twc-lab/values.yaml" ||
  fail "chart values do not default to us-east-1"

printf 'repository policy checks passed\n'
