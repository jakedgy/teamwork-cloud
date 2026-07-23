# Repository Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repository ready for public handoff with one canonical AWS region, a clear 0BSD licensing boundary, preserved third-party notices, contributor guardrails, and a documented GitHub settings recommendation.

**Architecture:** A small repository-policy test will enforce region and legal-document invariants alongside the existing Go, Helm, and lifecycle suites. License material will remain ordinary repository files and will also be copied into the final distroless image under `/licenses`; GitHub settings will be documented but not mutated.

**Tech Stack:** Bash, GNU Make, Go modules, Docker multi-stage builds, Markdown, Git, Helm, GitHub Actions.

---

## File map

| Path | Responsibility |
| --- | --- |
| `scripts/tests/repository_test.sh` | Fast policy checks for the canonical region, resolved dependency inventory, licensing files, and documentation links |
| `Makefile` | Includes repository policy checks in `make verify` |
| `README.md` | Public entry point for region, licensing, contributing, and settings guidance |
| `docs/runbook.md` | Canonical-region operational examples |
| `docs/repository-settings.md` | Observed GitHub posture and owner-approved recommendations; no mutation commands run automatically |
| `LICENSE` | 0BSD terms for original repository work |
| `THIRD_PARTY_NOTICES.md` | Human-readable mapping of compiled dependencies and separately distributed deployment components |
| `LICENSES/*` | Exact upstream license and notice texts for code compiled into the simulator |
| `CONTRIBUTING.md` | Clean-room, safety, verification, and submission rules |
| `Dockerfile` | Copies repository and compiled-dependency notices into the final image |
| `scripts/tests/container_test.sh` | Verifies `/licenses` without requiring a shell inside the distroless image |
| `scripts/{preflight,render-cluster-config,deploy}.sh` | Canonical AWS-region defaults |
| `charts/twc-lab/values.yaml` | Canonical region shown by the deployed simulator |
| `scripts/tests/operations_test.sh` | Canonical fake ARNs, Availability Zones, state, and assertions |
| Existing design and plan documents | Historical records updated so they do not advertise a competing default |

### Task 1: Enforce and migrate the canonical AWS region

**Files:**
- Create: `scripts/tests/repository_test.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `docs/runbook.md`
- Modify: `docs/superpowers/specs/2026-07-22-eks-teamwork-cloud-prototype-design.md`
- Modify: `docs/superpowers/plans/2026-07-22-eks-teamwork-cloud-prototype.md`
- Modify: `scripts/preflight.sh`
- Modify: `scripts/render-cluster-config.sh`
- Modify: `scripts/deploy.sh`
- Modify: `charts/twc-lab/values.yaml`
- Modify: `scripts/tests/operations_test.sh`
- Modify: `internal/config/config.go`
- Modify: `internal/config/config_test.go`
- Modify: `internal/web/server_test.go`

- [ ] **Step 1: Add a repository policy test that rejects the former Ohio-region identifier**

Create `scripts/tests/repository_test.sh` with this initial content. Splitting the old identifier prevents the test from matching itself.

```bash
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
```

Add the executable bit and wire it into the end of `make verify`, immediately after the lifecycle suite:

```make
	bash scripts/tests/operations_test.sh
	bash scripts/tests/repository_test.sh
```

- [ ] **Step 2: Run the test to prove the repository still violates the policy**

Run:

```bash
bash scripts/tests/repository_test.sh
```

Expected: non-zero exit with a list of tracked references to the former region and `FAIL: tracked files still reference the former default region`.

- [ ] **Step 3: Perform the mechanical region migration**

Replace the former region identifier with `us-east-1` in exactly these tracked files:

```text
README.md
docs/runbook.md
docs/superpowers/specs/2026-07-22-eks-teamwork-cloud-prototype-design.md
docs/superpowers/plans/2026-07-22-eks-teamwork-cloud-prototype.md
scripts/preflight.sh
scripts/render-cluster-config.sh
scripts/deploy.sh
charts/twc-lab/values.yaml
scripts/tests/operations_test.sh
internal/config/config.go
internal/config/config_test.go
internal/web/server_test.go
```

This is a literal token replacement only. It must update fake ARNs, fake stack IDs, `us-east-1a`/`us-east-1b` fixtures, expected diagnostic output, and AWS CLI assertions without changing lifecycle logic. Keep `${AWS_REGION:-us-east-1}` in all three scripts so explicit overrides continue to work.

- [ ] **Step 4: Run focused region and lifecycle verification**

Run:

```bash
bash scripts/tests/repository_test.sh
bash scripts/tests/operations_test.sh
go test ./internal/config ./internal/web
```

Expected: `repository policy checks passed`, the full lifecycle suite reports zero failures (currently 184 passing checks), and the focused Go packages pass.

- [ ] **Step 5: Commit the canonical-region change**

```bash
git add Makefile README.md docs/runbook.md \
  docs/superpowers/specs/2026-07-22-eks-teamwork-cloud-prototype-design.md \
  docs/superpowers/plans/2026-07-22-eks-teamwork-cloud-prototype.md \
  scripts/preflight.sh scripts/render-cluster-config.sh scripts/deploy.sh \
  scripts/tests/operations_test.sh scripts/tests/repository_test.sh \
  charts/twc-lab/values.yaml internal/config/config.go \
  internal/config/config_test.go internal/web/server_test.go \
  docs/superpowers/plans/2026-07-22-repository-readiness.md
git commit -m "chore: standardize examples on us-east-1"
```

### Task 2: Add the 0BSD and compiled-dependency licensing boundary

**Files:**
- Create: `LICENSE`
- Create: `THIRD_PARTY_NOTICES.md`
- Create: `LICENSES/gocql-LICENSE.txt`
- Create: `LICENSES/gocql-NOTICE.txt`
- Create: `LICENSES/golang-snappy-LICENSE.txt`
- Create: `LICENSES/go-hostpool-LICENSE.txt`
- Create: `LICENSES/inf-LICENSE.txt`
- Modify: `scripts/tests/repository_test.sh`

- [ ] **Step 1: Extend the repository policy test with failing legal-artifact checks**

Insert the following before the final success message in `scripts/tests/repository_test.sh`:

```bash
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

grep -Fq 'Zero-Clause BSD' "$ROOT/LICENSE" || fail "LICENSE is not labeled 0BSD"

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
while IFS='|' read -r repository_file upstream_file; do
  cmp -s "$ROOT/$repository_file" "$module_cache/$upstream_file" ||
    fail "$repository_file differs from its resolved upstream file"
done <<'EOF'
LICENSES/gocql-LICENSE.txt|github.com/gocql/gocql@v1.7.0/LICENSE
LICENSES/gocql-NOTICE.txt|github.com/gocql/gocql@v1.7.0/NOTICE
LICENSES/golang-snappy-LICENSE.txt|github.com/golang/snappy@v0.0.3/LICENSE
LICENSES/go-hostpool-LICENSE.txt|github.com/hailocab/go-hostpool@v0.0.0-20160125115350-e80d13ce29ed/LICENSE
LICENSES/inf-LICENSE.txt|gopkg.in/inf.v0@v0.9.1/LICENSE
EOF

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
    fail "THIRD_PARTY_NOTICES.md omits $component"
done
```

- [ ] **Step 2: Run the policy test to prove the legal artifacts are missing**

Run:

```bash
bash scripts/tests/repository_test.sh
```

Expected: non-zero exit with `FAIL: LICENSE is missing or empty`.

- [ ] **Step 3: Add the root 0BSD license**

Create `LICENSE` exactly as follows:

```text
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
```

- [ ] **Step 4: Add exact upstream license and notice files**

Create the five files below with the byte-for-byte content from the resolved module paths shown. Use `apply_patch` to add the reviewed text; use the SHA-256 values as an independent transcription check.

| Repository file | Resolved source below `$(go env GOMODCACHE)` | Expected SHA-256 |
| --- | --- | --- |
| `LICENSES/gocql-LICENSE.txt` | `github.com/gocql/gocql@v1.7.0/LICENSE` | `8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac` |
| `LICENSES/gocql-NOTICE.txt` | `github.com/gocql/gocql@v1.7.0/NOTICE` | `1493205786880af6bca5ab9be06484f82f2a66759535b10c5237e88522c54b57` |
| `LICENSES/golang-snappy-LICENSE.txt` | `github.com/golang/snappy@v0.0.3/LICENSE` | `f69f157b0be75da373605dbc8bbf142e8924ee82d8f44f11bcaf351335bf98cf` |
| `LICENSES/go-hostpool-LICENSE.txt` | `github.com/hailocab/go-hostpool@v0.0.0-20160125115350-e80d13ce29ed/LICENSE` | `3fd4d49e501188489a24a0cf875b0dab205ad775ba0bade9525fb4e4daff8547` |
| `LICENSES/inf-LICENSE.txt` | `gopkg.in/inf.v0@v0.9.1/LICENSE` | `050855d9ceedf916a9e9f30d20c6f61a484448d2c2ed5810934bc8aef43861b4` |

Do not normalize whitespace or combine texts. In particular, retain the complete Apache 2.0 license and the complete gocql `NOTICE`, including its historical BSD attribution and contributor list.

- [ ] **Step 5: Add the human-readable notices inventory**

Create `THIRD_PARTY_NOTICES.md` with these sections and exact inventory rows:

```markdown
# Third-party notices

The repository's original work is offered under the [Zero-Clause BSD license](LICENSE). That license does not replace the terms for third-party software compiled into the simulator, used as a container base, or downloaded by the deployment workflow.

## Code compiled into the simulator

| Module | Version | License and notice |
| --- | --- | --- |
| `github.com/gocql/gocql` | `v1.7.0` | Apache-2.0; [license](LICENSES/gocql-LICENSE.txt), [NOTICE](LICENSES/gocql-NOTICE.txt) |
| `github.com/golang/snappy` | `v0.0.3` | BSD-3-Clause; [license](LICENSES/golang-snappy-LICENSE.txt) |
| `github.com/hailocab/go-hostpool` | `v0.0.0-20160125115350-e80d13ce29ed` | MIT; [license](LICENSES/go-hostpool-LICENSE.txt) |
| `gopkg.in/inf.v0` | `v0.9.1` | BSD-3-Clause; [license](LICENSES/inf-LICENSE.txt) |

These versions are derived from `go.mod` and the packages reachable from `./cmd/twc-lab`. `make verify` fails if that compiled module set changes without a deliberate notice update.

## Separately distributed components

The lab references or downloads the components below; they are not relicensed by this repository. Their images and charts can contain additional transitive software and notice files, so the terms shipped with each downloaded artifact remain authoritative.

| Component referenced by this repository | Upstream project | Project license |
| --- | --- | --- |
| `cassandra:4.1.4` | [Apache Cassandra](https://github.com/apache/cassandra) | Apache-2.0 plus notices shipped with the image |
| `zookeeper:3.9.2` | [Apache ZooKeeper](https://github.com/apache/zookeeper) | Apache-2.0 plus notices shipped with the image |
| `apache/activemq-artemis:2.32.0` | [Apache ActiveMQ Artemis](https://github.com/apache/activemq-artemis) | Apache-2.0 plus notices shipped with the image |
| `ingress-nginx chart 4.13.3` | [Kubernetes ingress-nginx](https://github.com/kubernetes/ingress-nginx) | Apache-2.0 plus chart/image dependencies |
| `gcr.io/distroless/static-debian12` pinned by digest | [Distroless](https://github.com/GoogleContainerTools/distroless) | Apache-2.0 project code plus licenses for included Debian materials |
| `golang:1.26.5-alpine` pinned by digest, build stage only | [Go Docker Official Image](https://github.com/docker-library/golang) | Upstream Go, Alpine, and image-component terms; not present as the final runtime base |

The AWS CLI, `eksctl`, Kubernetes, Helm, Docker, Make, Bash, OpenSSL, `jq`, and GitHub Actions are tools or services used to build, verify, or operate the lab. They are acquired separately and remain under their own terms.

## Proprietary software boundary

No Teamwork Cloud or Web Application Platform binary, WAR, chart, license material, copied UI asset, or non-public documentation is distributed here. Product and company names are used only to describe the deployment topology that inspired this clearly labeled simulator. No compatibility, endorsement, activation, or trademark license is claimed.
```

- [ ] **Step 6: Verify the resolved module set and exact license copies**

Run:

```bash
bash scripts/tests/repository_test.sh
```

Expected: `repository policy checks passed`.

- [ ] **Step 7: Commit the repository licensing boundary**

```bash
git add LICENSE THIRD_PARTY_NOTICES.md LICENSES scripts/tests/repository_test.sh
git commit -m "docs: license original work under 0BSD"
```

### Task 3: Deliver notices inside the simulator image

**Files:**
- Modify: `Dockerfile`
- Modify: `scripts/tests/container_test.sh`

- [ ] **Step 1: Add failing container assertions for `/licenses`**

In `scripts/tests/container_test.sh`, define a temporary extraction directory after the image and container names:

```bash
license_dir=$(mktemp -d)
```

Add its cleanup to `cleanup()`:

```bash
  rm -rf "$license_dir"
```

After the container health loop and before fetching `/webapp`, add:

```bash
docker cp "${container}:/licenses/." "$license_dir"

for notice in \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  third-party/gocql-LICENSE.txt \
  third-party/gocql-NOTICE.txt \
  third-party/golang-snappy-LICENSE.txt \
  third-party/go-hostpool-LICENSE.txt \
  third-party/inf-LICENSE.txt; do
  if [[ ! -s "$license_dir/$notice" ]]; then
    echo "container license file '$notice' is missing or empty" >&2
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
```

`docker cp` is intentional because the distroless runtime has no shell.

- [ ] **Step 2: Run the container test to prove notices are absent**

Run:

```bash
make container-test
```

Expected: non-zero exit from `docker cp` because `/licenses` does not exist in the current image.

- [ ] **Step 3: Copy license artifacts into the final image**

In the final Docker stage, immediately after copying the binary, add:

```dockerfile
COPY --from=build /src/LICENSE /src/THIRD_PARTY_NOTICES.md /licenses/
COPY --from=build /src/LICENSES/ /licenses/third-party/
```

Keep `USER 65532:65532`; the files are read-only runtime documentation and require no application changes.

- [ ] **Step 4: Run the complete container contract**

Run:

```bash
make container-test
```

Expected: image builds, runs as `65532:65532`, serves `/healthz` and `/webapp`, includes all notice files, and prints `container contract passed`.

- [ ] **Step 5: Commit container notice delivery**

```bash
git add Dockerfile scripts/tests/container_test.sh
git commit -m "build: include third-party notices in image"
```

### Task 4: Add contributor and repository-settings guidance

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `docs/repository-settings.md`
- Modify: `README.md`
- Modify: `scripts/tests/repository_test.sh`

- [ ] **Step 1: Add failing documentation-policy assertions**

Insert these checks before the final success message in `scripts/tests/repository_test.sh`:

```bash
for required_file in CONTRIBUTING.md docs/repository-settings.md; do
  [[ -s "$ROOT/$required_file" ]] || fail "$required_file is missing or empty"
done

for readme_link in CONTRIBUTING.md THIRD_PARTY_NOTICES.md docs/repository-settings.md; do
  grep -Fq "($readme_link)" "$ROOT/README.md" ||
    fail "README.md does not link to $readme_link"
done

grep -Fq 'make verify' "$ROOT/CONTRIBUTING.md" ||
  fail "CONTRIBUTING.md omits make verify"
grep -Fq 'make container-test' "$ROOT/CONTRIBUTING.md" ||
  fail "CONTRIBUTING.md omits make container-test"
grep -Fq 'Existing VPCs are externally owned' "$ROOT/CONTRIBUTING.md" ||
  fail "CONTRIBUTING.md omits the existing-VPC boundary"
grep -Fq 'No settings are changed by repository automation' "$ROOT/docs/repository-settings.md" ||
  fail "repository settings guide does not state its non-mutating boundary"
```

- [ ] **Step 2: Run the policy test to prove handoff documents are absent**

Run:

```bash
bash scripts/tests/repository_test.sh
```

Expected: non-zero exit with `FAIL: CONTRIBUTING.md is missing or empty`.

- [ ] **Step 3: Add the contribution guide**

Create `CONTRIBUTING.md` with the following structure and requirements:

```markdown
# Contributing

Thanks for helping make this deployment lab easier to understand and safer to operate. This repository is an educational EKS prototype with a simulated product layer; it is not Teamwork Cloud software and does not claim product compatibility.

## Clean-room boundary

Contributions must use public information and original work. Do not submit proprietary vendor binaries, WARs, charts, license files or keys, copied UI assets, authenticated download contents, or excerpts from non-public documentation. Keep the application visibly labeled **Simulated product layer**, read-only, and free of fake activation or compatibility claims.

## Safety boundaries

- Ordinary pull requests must not require a paid AWS deployment. CI uses offline tests and local container builds.
- Existing VPCs are externally owned. Automation may validate explicitly supplied VPC and subnet IDs but must never create, route, tag, modify, or delete those network resources.
- Lifecycle changes must retain account/region/cluster identity checks, explicit teardown confirmation, bounded waits, and residual-resource checks.
- Never commit credentials, generated `.twc-lab/` state, downloaded vendor materials, or real project data.

## Before opening a pull request

Install the tools listed in the README, then run:

```bash
make verify
make container-test
```

`make verify` runs Go tests and vet, Helm rendering, shell syntax, offline lifecycle tests, and repository policy checks. `make container-test` requires Docker and verifies the non-root runtime, web contract, and bundled license notices.

Keep changes focused. Explain the real-versus-simulated boundary, operational impact, tests run, and any third-party dependency or image change. A dependency change must update `THIRD_PARTY_NOTICES.md`, the matching files under `LICENSES/`, and the container notice test.

## Licensing contributions

Unless explicitly stated otherwise, original contributions submitted for inclusion are offered under the repository's [Zero-Clause BSD license](LICENSE). Only submit work you have the right to contribute. Preserve and disclose third-party copyright, license, and notice requirements; 0BSD does not relicense third-party work.

## Pull-request checklist

- [ ] The product layer remains clearly labeled as simulated.
- [ ] No proprietary or sensitive material is included.
- [ ] Existing-network and teardown safety boundaries remain intact.
- [ ] `make verify` passes.
- [ ] `make container-test` passes when container behavior or packaging changes.
- [ ] Third-party notices are updated when dependencies or images change.

For a suspected vulnerability or exposed secret, do not include exploit details or credentials in a public issue. Contact the repository owner privately through their GitHub profile so the report can be handled before public discussion.
```

- [ ] **Step 4: Add the settings audit and recommendations**

Create `docs/repository-settings.md` with these sections:

```markdown
# Repository settings

This page records the handoff-time settings review. No settings are changed by repository automation; the owner must deliberately approve and apply administrative changes.

## Observed posture

- The repository is public and `main` is the default branch.
- Issues are enabled; Wiki and Discussions are disabled.
- Merge commits, squash merges, and rebase merges are enabled; merged branches are retained.
- GitHub Actions is enabled. The default workflow token is read-only and cannot approve pull-request reviews.
- Secret scanning and push protection are enabled.
- There is no branch protection or repository ruleset.
- There is no protected `eks-smoke` environment.
- Dependabot security updates are disabled.

## Recommended before broader collaboration

1. Add a ruleset for `main` that blocks force pushes and branch deletion and requires the `Verify` status check before merge.
2. Create an `eks-smoke` environment with required reviewers and restrict deployments to `main` before configuring its AWS OIDC role and variables.
3. Prefer squash merging and enable automatic deletion of merged branches for a compact prototype history.
4. Keep workflow-token permissions read-only by default. Retain secret scanning and push protection.

## Optional follow-ups

- Enable Dependabot security updates if the owner wants automated dependency pull requests and accepts their maintenance traffic.
- Require full commit-SHA pinning for Actions if organization policy demands it. Current workflows already pin third-party Actions explicitly.
- Add a security policy when the repository has a stable private reporting address.

The manual EKS smoke workflow creates paid AWS resources. Do not configure or run it until the protected environment, exact OIDC trust, account, and region have been reviewed.
```

- [ ] **Step 5: Link licensing, contributing, and settings guidance from README**

Add these bullets to the existing focused-guides list near the top of `README.md`:

```markdown
- [Contribution guide and clean-room rules](CONTRIBUTING.md)
- [Third-party licenses and notices](THIRD_PARTY_NOTICES.md)
- [Repository settings review](docs/repository-settings.md)
```

Add this final section after CI and image publication:

```markdown
## License and contributions

Original work in this repository is available under the [Zero-Clause BSD license](LICENSE). Third-party dependencies, images, charts, and tools remain under their own terms; see [third-party notices](THIRD_PARTY_NOTICES.md). Contributions are welcome under the focused [contribution guide](CONTRIBUTING.md).

The current GitHub posture and owner-controlled hardening recommendations are recorded in [repository settings](docs/repository-settings.md). Repository automation does not silently change those settings.
```

- [ ] **Step 6: Run repository and documentation verification**

Run:

```bash
bash scripts/tests/repository_test.sh
make verify
```

Expected: repository policy checks pass and `make verify` completes with zero failures.

- [ ] **Step 7: Commit the public handoff guidance**

```bash
git add CONTRIBUTING.md README.md docs/repository-settings.md scripts/tests/repository_test.sh
git commit -m "docs: add public contribution and settings guidance"
```

### Task 5: Run final verification and review the release boundary

**Files:**
- Verify only; modify earlier task files only if a check exposes a defect.

- [ ] **Step 1: Prove the former region identifier is absent from tracked files**

Run:

```bash
former_region='us-east''-2'
if git grep -n "$former_region" -- .; then
  echo 'former region identifier remains' >&2
  exit 1
fi
```

Expected: no matches and exit zero.

- [ ] **Step 2: Run all offline repository checks**

Run:

```bash
make verify
```

Expected: Go race tests, vet, Helm lint/render assertions, shell syntax, 184-or-more lifecycle checks, and repository policy checks all pass.

- [ ] **Step 3: Run ShellCheck with the same pinned version used during prior verification**

Run:

```bash
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 \
  scripts/*.sh scripts/tests/*.sh charts/twc-lab/tests/*.sh
```

Expected: exit zero with no diagnostics.

- [ ] **Step 4: Run the final container contract**

Run:

```bash
make container-test
```

Expected: `container contract passed`, including non-root execution and all `/licenses` assertions.

- [ ] **Step 5: Review the exact change boundary**

Run:

```bash
git status --short
git diff --check HEAD~4..HEAD
git diff --stat HEAD~4..HEAD
git log -5 --oneline
```

Expected: clean worktree, no whitespace errors, changes limited to region standardization, legal artifacts, image notices, contribution guidance, and settings documentation, with one focused commit per implementation task plus this plan commit.

- [ ] **Step 6: Push only after verification is green**

Run:

```bash
git push origin main
```

Expected: `main` advances without a force push. Then watch the new `Verify` workflow and report its final conclusion; do not create AWS resources or apply GitHub settings as part of this plan.
