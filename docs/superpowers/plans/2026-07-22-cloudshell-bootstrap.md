# CloudShell Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one safe command that installs missing CloudShell deployment tools and document the complete clone-to-deploy path.

**Architecture:** A Linux AMD64 Bash script reuses compatible Helm and eksctl versions or installs the repository's checksum-pinned versions into `$HOME/.local/bin`. Make prepends that directory to recipe `PATH`; the README shows clone, bootstrap, preflight, and deploy as separate commands.

**Tech Stack:** Bash, GNU Make, curl, tar, sha256sum, Markdown.

---

### Task 1: Add the CloudShell bootstrap and quickstart

**Files:**
- Create: `scripts/bootstrap-cloudshell.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `scripts/tests/repository_test.sh`

- [ ] **Step 1: Add failing repository-policy checks**

Before the final success message in `scripts/tests/repository_test.sh`, require the executable script, target, pins, and quickstart:

```bash
[[ -x "$ROOT/scripts/bootstrap-cloudshell.sh" ]] ||
  fail "scripts/bootstrap-cloudshell.sh is missing or not executable"
grep -Eq '^bootstrap-cloudshell:[[:space:]]*$' "$ROOT/Makefile" ||
  fail "Makefile omits bootstrap-cloudshell target"

for bootstrap_value in \
  'HELM_INSTALL_VERSION=v3.15.4' \
  'HELM_ARCHIVE_SHA256=11400fecfc07fd6f034863e4e0c4c4445594673fd2a129e701fe41f31170cfa9' \
  'EKSCTL_INSTALL_VERSION=v0.229.0' \
  'EKSCTL_ARCHIVE_SHA256=4a104d3a2a001de219e227baea1f0513ce6e87e60fef7dfc219cb0694e378829'; do
  grep -Fqx "$bootstrap_value" "$ROOT/scripts/bootstrap-cloudshell.sh" ||
    fail "CloudShell bootstrap omits exact pin: $bootstrap_value"
done

for quickstart_line in \
  'git clone https://github.com/jakedgy/teamwork-cloud.git' \
  'cd teamwork-cloud' \
  'make bootstrap-cloudshell' \
  'make preflight' \
  'make deploy'; do
  grep -Fqx "$quickstart_line" "$ROOT/README.md" ||
    fail "README CloudShell quickstart omits: $quickstart_line"
done
```

Run:

```bash
bash scripts/tests/repository_test.sh
```

Expected: `FAIL: scripts/bootstrap-cloudshell.sh is missing or not executable`.

- [ ] **Step 2: Create the minimal bootstrap script**

Create executable `scripts/bootstrap-cloudshell.sh`:

```bash
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

version_at_least() {
  local current=${1#v}
  local minimum=${2#v}
  local current_major current_minor current_patch minimum_major minimum_minor minimum_patch
  current=${current%%+*}
  current=${current%%-*}
  minimum=${minimum%%+*}
  minimum=${minimum%%-*}
  IFS=. read -r current_major current_minor current_patch <<<"$current"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<<"$minimum"
  [[ $current_major =~ ^[0-9]+$ && $current_minor =~ ^[0-9]+$ && $current_patch =~ ^[0-9]+$ ]] || return 1
  [[ $minimum_major =~ ^[0-9]+$ && $minimum_minor =~ ^[0-9]+$ && $minimum_patch =~ ^[0-9]+$ ]] || return 1
  (( 10#$current_major > 10#$minimum_major )) ||
    (( 10#$current_major == 10#$minimum_major && 10#$current_minor > 10#$minimum_minor )) ||
    (( 10#$current_major == 10#$minimum_major && 10#$current_minor == 10#$minimum_minor && 10#$current_patch >= 10#$minimum_patch ))
}

helm_is_compatible() {
  command -v helm >/dev/null 2>&1 || return 1
  local version
  version=$(helm version --short 2>/dev/null) || return 1
  version_at_least "$version" "$HELM_MIN_VERSION" && ! version_at_least "$version" "$HELM_MAX_VERSION"
}

eksctl_is_compatible() {
  command -v eksctl >/dev/null 2>&1 || return 1
  local version
  version=$(eksctl version 2>/dev/null) || return 1
  version_at_least "$version" "$EKSCTL_MIN_VERSION"
}

for command_name in curl install mkdir mktemp sha256sum tar uname; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command '$command_name' is unavailable"
done

[[ $(uname -s) == Linux ]] || fail "CloudShell bootstrap supports Linux only"
case $(uname -m) in
  x86_64|amd64) ;;
  *) fail "CloudShell bootstrap supports AMD64 only" ;;
esac

install_dir="${HOME:?HOME is required}/.local/bin"
mkdir -p "$install_dir"
temporary_dir=$(mktemp -d)
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

if helm_is_compatible; then
  printf 'Reusing %s\n' "$(helm version --short)"
else
  helm_archive="$temporary_dir/helm-${HELM_INSTALL_VERSION}-linux-amd64.tar.gz"
  curl --fail --location --silent --show-error \
    --output "$helm_archive" \
    "https://get.helm.sh/helm-${HELM_INSTALL_VERSION}-linux-amd64.tar.gz"
  printf '%s  %s\n' "$HELM_ARCHIVE_SHA256" "$helm_archive" | sha256sum --check --status
  tar --extract --gzip --file "$helm_archive" --directory "$temporary_dir"
  install -m 0755 "$temporary_dir/linux-amd64/helm" "$install_dir/helm"
  printf 'Installed Helm %s\n' "$HELM_INSTALL_VERSION"
fi

if eksctl_is_compatible; then
  printf 'Reusing eksctl %s\n' "$(eksctl version)"
else
  eksctl_archive="$temporary_dir/eksctl_Linux_amd64.tar.gz"
  curl --fail --location --silent --show-error \
    --output "$eksctl_archive" \
    "https://github.com/eksctl-io/eksctl/releases/download/${EKSCTL_INSTALL_VERSION}/eksctl_Linux_amd64.tar.gz"
  printf '%s  %s\n' "$EKSCTL_ARCHIVE_SHA256" "$eksctl_archive" | sha256sum --check --status
  tar --extract --gzip --file "$eksctl_archive" --directory "$temporary_dir" eksctl
  install -m 0755 "$temporary_dir/eksctl" "$install_dir/eksctl"
  printf 'Installed eksctl %s\n' "$EKSCTL_INSTALL_VERSION"
fi

PATH="$install_dir:$PATH"
export PATH
printf 'Helm: %s\n' "$(helm version --short)"
printf 'eksctl: %s\n' "$(eksctl version)"
printf 'For direct shell use: export PATH="$HOME/.local/bin:$PATH"\n'
```

- [ ] **Step 3: Add the Make target and recipe PATH**

At the top of `Makefile`, add:

```make
export PATH := $(HOME)/.local/bin:$(PATH)
```

Add `bootstrap-cloudshell` to `.PHONY` and add:

```make
bootstrap-cloudshell:
	bash scripts/bootstrap-cloudshell.sh
```

- [ ] **Step 4: Add the README CloudShell quickstart**

Before `## Prerequisites`, add:

````markdown
## AWS CloudShell quick start

Open public AWS CloudShell in **us-east-1 (N. Virginia)**, then run:

```bash
git clone https://github.com/jakedgy/teamwork-cloud.git
cd teamwork-cloud
make bootstrap-cloudshell
make preflight
make deploy
```

The bootstrap reuses compatible Helm and eksctl versions or installs the repository's checksum-pinned versions under `$HOME/.local/bin`. It does not use `sudo`, change your shell profile, call AWS APIs, or create resources. Public CloudShell persists `$HOME` separately in each AWS Region; VPC CloudShell environments do not persist it. Existing preflight still checks every deployment prerequisite and your active AWS identity before anything billable is created.
````

When writing the nested Markdown fence, use four tildes around the full example or otherwise preserve the inner Bash fence correctly.

- [ ] **Step 5: Run focused and full verification**

Run:

```bash
bash scripts/tests/repository_test.sh
bash -n scripts/bootstrap-cloudshell.sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 \
  scripts/bootstrap-cloudshell.sh
make verify
```

Expected: policy passes, syntax and ShellCheck are clean, and full verification reports 184 lifecycle passes and zero failures. Do not run `make bootstrap-cloudshell` on macOS; the script intentionally rejects non-Linux hosts.

- [ ] **Step 6: Commit**

```bash
git add Makefile README.md scripts/bootstrap-cloudshell.sh scripts/tests/repository_test.sh
git commit -m "feat: add CloudShell bootstrap"
```

Do not run AWS deployment or mutate shell profiles as part of verification.
