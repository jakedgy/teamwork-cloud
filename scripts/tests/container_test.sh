#!/usr/bin/env bash
set -euo pipefail

suffix="$$-${RANDOM}"
image="twc-lab:test-${suffix}"
container="twc-lab-container-test-${suffix}"
license_dir=$(mktemp -d)
curl_args=(--connect-timeout 2 --fail --silent --show-error)

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
  rm -rf "$license_dir"
}
trap cleanup EXIT

for pattern in '^ARG TARGETOS$' '^ARG TARGETARCH$' 'GOOS=\$\{TARGETOS\}' 'GOARCH=\$\{TARGETARCH\}'; do
  if ! grep -Eq "$pattern" Dockerfile; then
    echo "Dockerfile missing controlled platform setting: $pattern" >&2
    exit 1
  fi
done

target_arch="$(docker info --format '{{.Architecture}}')"
case "$target_arch" in
  aarch64) target_arch="arm64" ;;
  x86_64) target_arch="amd64" ;;
esac

docker build --platform "linux/${target_arch}" \
  --build-arg TARGETOS=linux --build-arg TARGETARCH="$target_arch" \
  -t "$image" .

user="$(docker image inspect --format '{{.Config.User}}' "$image")"
if [[ "$user" != "65532:65532" ]]; then
  echo "image user is '$user', want '65532:65532'" >&2
  exit 1
fi

docker run --detach --name "$container" --publish 127.0.0.1::8080 "$image" >/dev/null
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$container")"
base_url="http://127.0.0.1:${port}"

deadline=$((SECONDS + 20))
while true; do
  remaining=$((deadline - SECONDS))
  if (( remaining <= 0 )); then
    echo "simulator did not become healthy within 20 seconds" >&2
    docker logs "$container" >&2 || true
    exit 1
  fi
  request_timeout=$((remaining < 3 ? remaining : 3))
  if curl "${curl_args[@]}" --max-time "$request_timeout" "${base_url}/healthz" >/dev/null; then
    break
  fi
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container")" != "true" ]]; then
    echo "simulator container exited before becoming healthy" >&2
    docker logs "$container" >&2 || true
    exit 1
  fi
  sleep 1
done

docker cp "${container}:/licenses/." "$license_dir"

for mapping in \
  'LICENSE|LICENSE' \
  'THIRD_PARTY_NOTICES.md|THIRD_PARTY_NOTICES.md' \
  'third-party/gocql-LICENSE.txt|LICENSES/gocql-LICENSE.txt' \
  'third-party/gocql-NOTICE.txt|LICENSES/gocql-NOTICE.txt' \
  'third-party/golang-snappy-LICENSE.txt|LICENSES/golang-snappy-LICENSE.txt' \
  'third-party/go-hostpool-LICENSE.txt|LICENSES/go-hostpool-LICENSE.txt' \
  'third-party/inf-LICENSE.txt|LICENSES/inf-LICENSE.txt'; do
  IFS='|' read -r image_path source_path <<< "$mapping"
  if [[ ! -s "$license_dir/$image_path" ]]; then
    echo "container license file '$image_path' is missing or empty" >&2
    exit 1
  fi
  if ! cmp -s "$license_dir/$image_path" "$source_path"; then
    echo "container license file '$image_path' differs from repository source '$source_path'" >&2
    exit 1
  fi
done

if ! grep -Fq 'Zero-Clause BSD' "$license_dir/LICENSE"; then
  echo 'container LICENSE is not the repository 0BSD license' >&2
  exit 1
fi
if ! grep -Fq 'Apache Cassandra GoCQL Driver' "$license_dir/third-party/gocql-NOTICE.txt"; then
  echo 'container does not carry the gocql NOTICE' >&2
  exit 1
fi

webapp="$(curl "${curl_args[@]}" --max-time 3 "${base_url}/webapp")"
if [[ "$webapp" != *"Simulated product layer"* ]]; then
  echo "webapp did not identify the simulated product layer" >&2
  exit 1
fi

echo "container contract passed"
