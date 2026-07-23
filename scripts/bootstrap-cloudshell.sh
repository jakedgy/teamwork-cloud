#!/usr/bin/env bash
set -euo pipefail

HELM_INSTALL_VERSION=v3.15.4
HELM_MIN_VERSION=3.15.4
HELM_MAX_VERSION=4.0.0
HELM_ARCHIVE_SHA256=11400fecfc07fd6f034863e4e0c4c4445594673fd2a129e701fe41f31170cfa9
EKSCTL_INSTALL_VERSION=v0.229.0
EKSCTL_MIN_VERSION=0.229.0
EKSCTL_ARCHIVE_SHA256=4a104d3a2a001de219e227baea1f0513ce6e87e60fef7dfc219cb0694e378829

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

normalized_version() {
  local version

  version=${1#v}
  version=${version%%[-+]*}
  [[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

version_at_least() {
  local candidate minimum
  local candidate_major candidate_minor candidate_patch
  local minimum_major minimum_minor minimum_patch

  candidate=$(normalized_version "$1") || return 1
  minimum=$(normalized_version "$2") || return 1
  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<<"$minimum"

  if (( 10#$candidate_major != 10#$minimum_major )); then
    (( 10#$candidate_major > 10#$minimum_major ))
  elif (( 10#$candidate_minor != 10#$minimum_minor )); then
    (( 10#$candidate_minor > 10#$minimum_minor ))
  else
    (( 10#$candidate_patch >= 10#$minimum_patch ))
  fi
}

for required_command in curl install mkdir mktemp rm sha256sum tar uname; do
  command -v "$required_command" >/dev/null 2>&1 ||
    fail "required command not found: $required_command"
done

[[ $(uname -s) == Linux ]] || fail "AWS CloudShell bootstrap requires Linux"
case $(uname -m) in
  x86_64 | amd64) ;;
  *) fail "AWS CloudShell bootstrap requires an x86_64/amd64 host" ;;
esac

: "${HOME:?HOME is required}"
INSTALL_DIR=$HOME/.local/bin
mkdir -p "$INSTALL_DIR"

TEMP_DIR=$(mktemp -d) || fail "unable to create a temporary directory"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

PATH=$INSTALL_DIR:$PATH
export PATH

helm_compatible=false
if command -v helm >/dev/null 2>&1; then
  if helm_version=$(helm version --short 2>/dev/null) &&
    version_at_least "$helm_version" "$HELM_MIN_VERSION" &&
    ! version_at_least "$helm_version" "$HELM_MAX_VERSION"; then
    helm_compatible=true
  fi
fi

if [[ $helm_compatible != true ]]; then
  helm_archive=$TEMP_DIR/helm.tar.gz
  helm_url=https://get.helm.sh/helm-${HELM_INSTALL_VERSION}-linux-amd64.tar.gz
  curl --fail --location --silent --show-error --output "$helm_archive" "$helm_url" ||
    fail "unable to download Helm $HELM_INSTALL_VERSION"
  printf '%s  %s\n' "$HELM_ARCHIVE_SHA256" "$helm_archive" |
    sha256sum --check --status || fail "Helm archive checksum verification failed"
  tar -xzf "$helm_archive" -C "$TEMP_DIR" linux-amd64/helm ||
    fail "unable to extract Helm archive"
  install -m 0755 "$TEMP_DIR/linux-amd64/helm" "$INSTALL_DIR/helm" ||
    fail "unable to install Helm"
fi

eksctl_compatible=false
if command -v eksctl >/dev/null 2>&1; then
  if eksctl_version=$(eksctl version 2>/dev/null) &&
    version_at_least "$eksctl_version" "$EKSCTL_MIN_VERSION"; then
    eksctl_compatible=true
  fi
fi

if [[ $eksctl_compatible != true ]]; then
  eksctl_archive=$TEMP_DIR/eksctl.tar.gz
  eksctl_url=https://github.com/eksctl-io/eksctl/releases/download/${EKSCTL_INSTALL_VERSION}/eksctl_Linux_amd64.tar.gz
  curl --fail --location --silent --show-error --output "$eksctl_archive" "$eksctl_url" ||
    fail "unable to download eksctl $EKSCTL_INSTALL_VERSION"
  printf '%s  %s\n' "$EKSCTL_ARCHIVE_SHA256" "$eksctl_archive" |
    sha256sum --check --status || fail "eksctl archive checksum verification failed"
  mkdir -p "$TEMP_DIR/eksctl"
  tar -xzf "$eksctl_archive" -C "$TEMP_DIR/eksctl" eksctl ||
    fail "unable to extract eksctl archive"
  install -m 0755 "$TEMP_DIR/eksctl/eksctl" "$INSTALL_DIR/eksctl" ||
    fail "unable to install eksctl"
fi

printf 'helm: %s\n' "$(helm version --short)"
printf 'eksctl: %s\n' "$(eksctl version)"
printf 'To use these tools in future shells, optionally run:\n'
printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
