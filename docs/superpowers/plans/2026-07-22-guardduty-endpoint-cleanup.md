# GuardDuty Endpoint Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `make destroy` to safely remove an orphaned GuardDuty data endpoint when it blocks deletion of the recorded lab-managed VPC.

**Architecture:** Replace the opaque CloudFormation waiter with bounded status polling against the exact recorded stack ID. After a short grace period, query only the recorded VPC and delete exactly one interface endpoint only when its service name, `GuardDutyManaged=true` tag, and ownership fields match the allowlist; otherwise fail closed and preserve local state.

**Tech Stack:** Bash, AWS CLI, shell integration tests

---

### Task 1: Prove guarded remediation behavior

**Files:**
- Modify: `scripts/tests/operations_test.sh`

- [x] Add a fake stalled stack and GuardDuty endpoint lifecycle to the AWS CLI test double.
- [x] Add a test proving a uniquely verified endpoint is deleted after stack deletion starts.
- [x] Add tests proving non-matching, ambiguous, and unauthorized endpoint lookups fail without deletion.
- [x] Run `bash scripts/tests/operations_test.sh` and verify the new tests fail because endpoint remediation is not implemented.

### Task 2: Implement bounded stack deletion

**Files:**
- Modify: `scripts/lib.sh`
- Modify: `scripts/destroy.sh`

- [x] Add validated `STACK_WAIT_SECONDS` and `STACK_DEPENDENCY_GRACE_SECONDS` settings.
- [x] Add a helper that queries the recorded VPC and deletes only one fully allowlisted GuardDuty data endpoint.
- [x] Replace `aws cloudformation wait` with exact-stack-ID polling, invoking remediation once after the grace period.
- [x] Preserve state and emit a specific diagnostic on timeout, lookup failure, ambiguity, or unexpected stack status.
- [x] Run `bash scripts/tests/operations_test.sh` and verify all tests pass.

### Task 3: Document and verify

**Files:**
- Modify: `docs/runbook.md`

- [x] Document automatic guarded endpoint cleanup and the fail-closed behavior.
- [x] Run `make verify`.
- [x] Review `git diff --check`, `git status --short`, and the final diff for scope and safety.
