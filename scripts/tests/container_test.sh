#!/usr/bin/env bash
set -euo pipefail

image="twc-lab:test"
container="twc-lab-container-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -t "$image" .

user="$(docker image inspect --format '{{.Config.User}}' "$image")"
if [[ "$user" != "65532:65532" ]]; then
  echo "image user is '$user', want '65532:65532'" >&2
  exit 1
fi

docker run --detach --name "$container" --publish 127.0.0.1::8080 "$image" >/dev/null
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$container")"
base_url="http://127.0.0.1:${port}"

deadline=$((SECONDS + 20))
until curl --fail --silent --show-error "${base_url}/healthz" >/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "simulator did not become healthy within 20 seconds" >&2
    docker logs "$container" >&2 || true
    exit 1
  fi
  sleep 1
done

webapp="$(curl --fail --silent --show-error "${base_url}/webapp")"
if [[ "$webapp" != *"Simulated product layer"* ]]; then
  echo "webapp did not identify the simulated product layer" >&2
  exit 1
fi

echo "container contract passed"
