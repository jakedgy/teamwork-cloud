# Repository settings

No settings are changed by repository automation. The repository owner must review, approve, and apply every administrative change described here.

## Observed posture

The repository posture below was observed on 2026-07-22 using GitHub's API:

- The repository is public and uses `main` as its default branch.
- Issues are enabled; the wiki and Discussions are disabled.
- Merge commits, squash merges, and rebase merges are all enabled, and merged branches are retained.
- GitHub Actions is enabled. Its default token is read-only and cannot approve pull request reviews.
- Secret scanning and push protection are enabled.
- No branch protection or repository ruleset protects `main`.
- The `eks-smoke` environment does not exist.
- Dependabot security updates are disabled.

## Recommended owner-controlled hardening

- Add a ruleset for `main` that blocks force pushes and deletion and requires the `Verify` status check before merging.
- Create the `eks-smoke` environment, configure required reviewers, and restrict deployments to `main` before configuring its OIDC role and variables.
- Prefer squash merges and automatically delete branches after merging to keep history and branch state focused.
- Retain the read-only Actions token, secret scanning, and push protection.

## Optional decisions

- Consider Dependabot security updates. They improve update visibility but also create maintenance traffic and still require review, notice updates, and verification.
- Consider enforcing full commit SHA pinning for Actions. The workflows already pin actions by full SHA, so enforcement would make that convention an administrative guarantee.
- Keep security reporting in GitHub Issues unless the repository owner deliberately changes that policy.

The `eks-smoke` workflow creates paid AWS resources. Do not configure or run it until the environment protection, OIDC trust, AWS account, and region have all been reviewed.
