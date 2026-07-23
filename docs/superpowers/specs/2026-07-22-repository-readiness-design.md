# Repository Readiness Design

**Date:** 2026-07-22  
**Status:** Approved for implementation planning

## Summary

Prepare the public repository for handoff by making `us-east-1` its canonical AWS region, licensing the repository's original work under 0BSD, preserving the licenses and notices of third-party software, documenting contribution boundaries, and recording a focused GitHub settings recommendation.

This work changes repository defaults and documentation only. It does not deploy paid AWS resources, alter an existing VPC, or change GitHub repository settings without a separate explicit approval.

## Decisions

- Use `us-east-1` as the default and documented AWS region everywhere in the repository.
- Keep `AWS_REGION` as an explicit override for users deploying elsewhere.
- License original repository code, documentation, scripts, and configuration under 0BSD.
- Preserve the licenses and required notices for all third-party source dependencies and container images; 0BSD does not relicense those works.
- Add a contribution guide designed for a public, clean-room simulator repository.
- Treat GitHub settings changes as a separate, reviewable administrative action.

## Region Standardization

All tracked examples of the former Ohio-region default, along with its fake ARNs, Availability Zones, test fixtures, and historical project documents, will become `us-east-1`. This includes:

- `README.md` and operational runbooks.
- Shell-script defaults and rendered cluster configuration.
- Helm values that display or propagate the region.
- Operation-test fixtures, assertions, fake resource identifiers, and fake Availability Zones.
- The original design and implementation plan, so repository search does not imply two competing defaults.

The implementation is complete when a tracked-file search finds no occurrences of the former region identifier. Region-independent behavior remains intact: setting `AWS_REGION` must continue to override the default, and lifecycle state must continue to bind operations to the chosen account, region, and cluster.

## Licensing Model

### Original repository work

A root `LICENSE` file will contain the standard 0BSD text and identify the repository copyright holder. 0BSD is intentionally permissive and does not require downstream attribution. The README will state that this license applies to original repository work only.

### Third-party source dependencies

The simulator's compiled Go dependency graph includes software under licenses other than 0BSD. At the time of this design, direct and transitive dependencies include:

- `github.com/gocql/gocql v1.7.0`: Apache License 2.0, including its upstream `NOTICE`.
- `github.com/golang/snappy v0.0.3`: BSD 3-Clause.
- `github.com/hailocab/go-hostpool`: MIT.
- `gopkg.in/inf.v0 v0.9.1`: BSD 3-Clause.

The implementation will add `THIRD_PARTY_NOTICES.md` as the human-readable inventory and a `LICENSES/` directory containing the applicable license and notice texts. Version and license claims will be checked against the resolved Go module graph rather than copied from memory.

The final simulator image will include these files under `/licenses`. A container test will verify their presence, ensuring redistributors of the image receive the same notices as repository users.

### Third-party images and deployment components

The Helm chart references separately distributed Cassandra, ZooKeeper, Artemis, ingress-nginx, and distroless images or charts. Those works remain under their respective upstream licenses. The notices inventory will identify them as external components, link to their upstream projects, and make clear that their license terms apply when downloaded or run.

No proprietary Teamwork Cloud package, chart, binary, WAR, license material, UI asset, or documentation excerpt will be added. The simulator will remain clearly labeled as a simulator and will make no compatibility or activation claim.

## Contribution Guide

`CONTRIBUTING.md` will cover:

- The project's educational, simulated-product scope.
- A clean-room rule prohibiting proprietary vendor binaries, charts, license material, copied UI assets, and non-public documentation content.
- A requirement to keep the product layer visibly labeled as simulated, read-only, and free of unsupported compatibility claims.
- The standard local checks: `make verify` and `make container-test`.
- The rule that paid AWS deployment is not expected for ordinary contributions or pull requests.
- Existing-VPC safety: validation may inspect supplied networks, but repository automation must not mutate or delete them.
- Lifecycle safety expectations for state identity, explicit teardown confirmation, and residual-resource checks.
- A statement that submitted original contributions are offered under 0BSD and that contributors must disclose and preserve third-party licenses.
- A concise pull-request checklist and security-reporting direction.

The guide will favor useful guardrails over a heavyweight governance process. A contributor license agreement, developer certificate sign-off bot, code of conduct, issue templates, and release process are outside this change.

## GitHub Settings Review

The current repository is public, uses `main`, enables Issues, has read-only default workflow permissions, and has secret scanning and push protection enabled. It has no branch protection or ruleset, no protected deployment environment, and permits all supported merge methods.

The implementation will document a recommended settings patch rather than applying it automatically:

- Protect `main` with a ruleset that blocks force pushes and deletion and requires the `Verify` workflow before merge.
- Create a protected `eks-smoke` environment before any workflow is allowed to create paid AWS resources.
- Prefer squash merging and automatically delete merged branches for a small prototype repository.
- Keep workflow tokens read-only by default and retain secret scanning and push protection.
- Treat Dependabot security updates and Actions SHA enforcement as optional follow-ups, because enabling either may add maintenance overhead beyond the handoff goal.

Any setting mutation requires the repository owner's separate approval because it changes collaboration behavior outside the working tree.

## Validation

Implementation validation will include:

1. A tracked-file search proving that the former region identifier no longer appears.
2. The full `make verify` suite, including Helm rendering and operation tests.
3. ShellCheck against all maintained shell scripts.
4. `make container-test`, extended to prove `/licenses` contains the expected notices.
5. A review of the resolved Go module graph against `THIRD_PARTY_NOTICES.md`.
6. Documentation link and command checks already included in repository verification.
7. A final diff review confirming that no proprietary material or unrelated behavior entered the change.

Live EKS deployment is not required to validate this repository-readiness change. The later EKS smoke test remains a separate, explicitly approved paid operation.

## Acceptance Criteria

- `us-east-1` is the sole repository default and documented example region, while `AWS_REGION` overrides still work.
- Root `LICENSE`, `THIRD_PARTY_NOTICES.md`, `LICENSES/`, and `CONTRIBUTING.md` are present and internally consistent.
- The simulator image carries third-party notices under `/licenses`.
- README licensing and contribution sections accurately distinguish original and third-party work.
- The settings recommendation reflects the observed repository configuration and does not silently mutate GitHub.
- All offline verification and container checks pass.
