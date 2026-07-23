# CloudShell Bootstrap Design

**Date:** 2026-07-22  
**Status:** Approved for implementation planning

## Goal

Let a friend open public AWS CloudShell, clone the repository, and get the two missing deployment tools with one command:

```bash
git clone https://github.com/jakedgy/teamwork-cloud.git
cd teamwork-cloud
make bootstrap-cloudshell
make preflight
make deploy
```

## Interface

Add `make bootstrap-cloudshell`, backed by `scripts/bootstrap-cloudshell.sh`.

The script targets standard Linux AMD64 AWS CloudShell. It reuses:

- Helm `>=3.15.4` and `<4.0.0`.
- eksctl `>=0.229.0`.

If either tool is absent or outside that tested range, the script installs the repository's proven version into `$HOME/.local/bin`:

- Helm `v3.15.4`, archive SHA-256 `11400fecfc07fd6f034863e4e0c4c4445594673fd2a129e701fe41f31170cfa9`.
- eksctl `v0.229.0`, archive SHA-256 `4a104d3a2a001de219e227baea1f0513ce6e87e60fef7dfc219cb0694e378829`.

Both archives come from their official HTTPS release locations. Downloads use a temporary directory, must pass `sha256sum`, and are installed without `sudo`. The script is idempotent and prints the final versions. It never calls AWS APIs or starts deployment.

The Makefile prepends `$HOME/.local/bin` to recipe `PATH`, so a later `make preflight` sees the installed tools without modifying `.bashrc`. The script prints an optional `export PATH=...` line for users who want to call the tools directly.

## Boundaries

- Install only Helm and eksctl. Existing preflight continues to report any other missing prerequisite.
- Do not install packages globally, edit shell profiles, use `curl | bash`, or require Docker.
- Fail clearly on non-Linux or non-AMD64 systems instead of guessing.
- Document that public CloudShell persists `$HOME` by region, while VPC CloudShell environments do not persist it.
- Do not run `make preflight` or create paid resources automatically.

## Verification

- Repository policy checks require the Make target, exact pinned versions/checksums, and the clone/bootstrap/preflight quickstart lines.
- `bash -n` and pinned ShellCheck cover the new script.
- `make verify` remains offline and does not download tools.
- A manual Linux smoke run verifies reuse of compatible tools and a clean-home install from the official archives.

## Non-goals

No general workstation installer, package manager abstraction, ARM support, version manager, automatic updates, CloudShell image customization, or one-line remote script execution.
