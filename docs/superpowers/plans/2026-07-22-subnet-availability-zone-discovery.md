# Subnet Availability Zone Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AWS subnet discovery parse real AWS CLI text output correctly for two or more subnets and reject selections containing multiple subnets in one Availability Zone.

**Architecture:** Keep subnet discovery in the existing preflight and renderer scripts, but change their JMESPath queries from lists of joined scalar strings to multiselect lists that AWS CLI renders one record per line. Validate exact subnet membership and unique Availability Zones before rendering eksctl YAML, and make the fake AWS CLI reproduce both the broken and corrected output shapes.

**Tech Stack:** Bash 3.2, AWS CLI v2 JMESPath queries, eksctl ClusterConfig YAML, shell integration tests

---

## File Structure

- `scripts/tests/operations_test.sh`: model AWS CLI text rendering and add deployment/preflight regression cases.
- `scripts/render-cluster-config.sh`: discover subnet records and validate exact subnet and Availability Zone membership before writing YAML.
- `scripts/preflight.sh`: use row-oriented subnet output and reject duplicate Availability Zones in existing-network mode.
- `scripts/deploy.sh`: suppress the inherited `ERR` trap for the expected absent-stack lookup.

### Task 1: Reproduce real AWS CLI subnet output

**Files:**
- Modify: `scripts/tests/operations_test.sh:53-62`
- Test: `scripts/tests/operations_test.sh`

- [x] **Step 1: Make the fake AWS CLI distinguish scalar joins from multiselect lists**

Update the `ec2 describe-subnets` fake so joined results reproduce AWS CLI's single-line text output when `FAKE_REAL_AWS_TEXT=1`, while multiselect-list queries retain one record per line:

```bash
  "ec2 describe-subnets")
    if [[ "$*" == *"Subnets[].[AvailabilityZone,SubnetId]"* ]]; then
      printf '%b\n' "${FAKE_AZ_ROWS:-us-east-1a\tsubnet-a\nus-east-1b\tsubnet-b}"
    elif [[ "$*" == *"AvailabilityZone,SubnetId"* ]]; then
      rows=${FAKE_AZ_ROWS:-$'us-east-1a\tsubnet-a\nus-east-1b\tsubnet-b'}
      if [[ "${FAKE_REAL_AWS_TEXT:-0}" == 1 ]]; then
        printf '%s\n' "${rows//$'\n'/$'\t'}"
      else
        printf '%s\n' "$rows"
      fi
    elif [[ "$*" == *"Subnets[].[SubnetId,AvailabilityZone"* ]]; then
      printf '%b\n' "${FAKE_SUBNET_ROWS:-subnet-a\tus-east-1a\t32\tTrue\t1\nsubnet-b\tus-east-1b\t32\tTrue\t1}"
    else
      [[ "$*" == *'join(`\t`'* ]] || exit 2
      rows=${FAKE_SUBNET_ROWS:-$'subnet-a\tus-east-1a\t32\tTrue\t1\nsubnet-b\tus-east-1b\t32\tTrue\t1'}
      if [[ "${FAKE_REAL_AWS_TEXT:-0}" == 1 ]]; then
        printf '%s\n' "${rows//$'\n'/$'\t'}"
      else
        printf '%s\n' "$rows"
      fi
    fi
    ;;
```

- [x] **Step 2: Add regressions for managed and existing subnet discovery**

After the existing managed deployment test, add:

```bash
new_case
expect_ok "managed deploy parses real AWS text subnet rows" run_script deploy.sh FAKE_REAL_AWS_TEXT=1 CONFIRM=1

new_case
expect_ok "existing deploy accepts three distinct subnet availability zones" run_script deploy.sh \
  NETWORK_MODE=existing VPC_ID=vpc-123456 \
  PUBLIC_SUBNET_IDS=subnet-a,subnet-b,subnet-c \
  $'FAKE_SUBNET_ROWS=subnet-a\tus-east-1a\t32\tTrue\t1\nsubnet-b\tus-east-1b\t32\tTrue\t1\nsubnet-c\tus-east-1c\t32\tTrue\t1' \
  $'FAKE_AZ_ROWS=us-east-1a\tsubnet-a\nus-east-1b\tsubnet-b\nus-east-1c\tsubnet-c' \
  FAKE_REAL_AWS_TEXT=1 CONFIRM=1
```

After the existing Availability Zone validation test, add:

```bash
new_case
expect_fail "existing subnets cannot share an availability zone" run_script preflight.sh \
  NETWORK_MODE=existing VPC_ID=vpc-123456 \
  PUBLIC_SUBNET_IDS=subnet-a,subnet-b,subnet-c \
  $'FAKE_SUBNET_ROWS=subnet-a\tus-east-1a\t32\tTrue\t1\nsubnet-b\tus-east-1a\t32\tTrue\t1\nsubnet-c\tus-east-1b\t32\tTrue\t1'
if grep -Fq "Selected subnets must use distinct availability zones" "$TEST_ROOT/err"; then
  record "duplicate subnet availability zone has a clear error" pass
else
  record "duplicate subnet availability zone has a clear error" fail
fi
```

- [x] **Step 3: Add renderer exact-membership regressions**

Add managed deployment cases that require every requested subnet exactly once:

```bash
new_case
expect_fail "renderer rejects an omitted requested subnet" run_script deploy.sh \
  $'FAKE_AZ_ROWS=us-east-1a\tsubnet-ma' CONFIRM=1
if grep -Fq "Could not discover every requested subnet availability zone" "$TEST_ROOT/err"; then
  record "omitted subnet has an exact renderer error" pass
else
  record "omitted subnet has an exact renderer error" fail
fi

new_case
expect_fail "renderer rejects a duplicate returned subnet" run_script deploy.sh \
  $'FAKE_AZ_ROWS=us-east-1a\tsubnet-ma\nus-east-1b\tsubnet-ma' CONFIRM=1

new_case
expect_fail "renderer rejects multiple subnets in one availability zone" run_script deploy.sh \
  $'FAKE_AZ_ROWS=us-east-1a\tsubnet-ma\nus-east-1a\tsubnet-mb' CONFIRM=1
```

- [x] **Step 4: Run the operational suite and verify RED**

Run:

```bash
bash scripts/tests/operations_test.sh
```

Expected: the new real-AWS-text managed deployment, three-subnet existing deployment, exact omitted-subnet error assertion, duplicate-returned-subnet case, renderer duplicate-AZ case, and clear preflight duplicate-AZ assertion fail because production still uses scalar joins and lacks exact renderer validation.

- [x] **Step 5: Commit the failing regression tests**

```bash
git add scripts/tests/operations_test.sh
git commit -m "test: reproduce AWS subnet text output"
```

### Task 2: Correct existing-network subnet discovery

**Files:**
- Modify: `scripts/preflight.sh:71-108`
- Test: `scripts/tests/operations_test.sh`

- [x] **Step 1: Replace the joined scalar query with a multiselect-list query**

Change the `describe-subnets` query to:

```bash
rows=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --subnet-ids "${CSV_VALUES[@]}" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].[SubnetId,AvailabilityZone,to_string(AvailableIpAddressCount),to_string(MapPublicIpOnLaunch),not_null(Tags[?Key=='kubernetes.io/role/elb']|[0].Value, \`None\`)]" \
  --output text)
```

- [x] **Step 2: Reject a repeated Availability Zone**

Replace the unique-AZ counter branch inside the record loop with:

```bash
    [[ -n $az ]] || die "AWS returned subnet $subnet without an availability zone"
    [[ $az_csv != *",$az,"* ]] || die "Selected subnets must use distinct availability zones"
    az_csv="${az_csv}${az},"
    az_count=$((az_count + 1))
```

Keep the final `az_count >= 2` guard as defense in depth.

- [x] **Step 3: Run the existing-network regression cases**

Run:

```bash
bash scripts/tests/operations_test.sh
```

Expected: existing-network real-text and duplicate-AZ cases pass; managed renderer cases remain failing.

- [x] **Step 4: Commit the preflight fix**

```bash
git add scripts/preflight.sh scripts/tests/operations_test.sh
git commit -m "fix: parse existing subnet records by row"
```

### Task 3: Validate renderer subnet membership and Availability Zones

**Files:**
- Modify: `scripts/render-cluster-config.sh:23-38`
- Test: `scripts/tests/operations_test.sh`

- [x] **Step 1: Use row-oriented AWS CLI output**

Replace the renderer query with:

```bash
rows=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --subnet-ids "${CSV_VALUES[@]}" \
  --query 'Subnets[].[AvailabilityZone,SubnetId]' \
  --output text)
```

- [x] **Step 2: Validate exact subnet membership and unique Availability Zones**

Before creating the temporary YAML file, validate the records:

```bash
requested_count=${#CSV_VALUES[@]}
seen_count=0
seen_subnets=,
seen_azs=,
while IFS=$'\t' read -r az subnet; do
  [[ -n ${az:-} && -n ${subnet:-} ]] ||
    die "AWS returned an incomplete subnet availability zone record"
  requested_subnet=0
  for requested_id in "${CSV_VALUES[@]}"; do
    [[ $subnet == "$requested_id" ]] && requested_subnet=1
  done
  (( requested_subnet == 1 )) || die "AWS returned an unexpected subnet: $subnet"
  [[ $seen_subnets != *",$subnet,"* ]] ||
    die "AWS returned subnet $subnet more than once"
  [[ $seen_azs != *",$az,"* ]] ||
    die "Selected subnets must use distinct availability zones"
  seen_subnets="${seen_subnets}${subnet},"
  seen_azs="${seen_azs}${az},"
  seen_count=$((seen_count + 1))
done <<<"$rows"
(( seen_count == requested_count )) ||
  die "Could not discover every requested subnet availability zone"
(( seen_count >= 2 )) ||
  die "Could not discover at least two subnet availability zones"
```

- [x] **Step 3: Run the operational suite and verify GREEN**

Run:

```bash
bash scripts/tests/operations_test.sh
```

Expected: `197 passed, 0 failed` before the diagnostic regression is added.

- [x] **Step 4: Commit the renderer fix**

```bash
git add scripts/render-cluster-config.sh
git commit -m "fix: validate rendered subnet availability zones"
```

### Task 4: Remove misleading expected-probe diagnostics

**Files:**
- Modify: `scripts/deploy.sh:67`
- Test: `scripts/tests/operations_test.sh`

- [x] **Step 1: Add a diagnostic regression assertion**

In the managed real-AWS-text deployment case, assert:

```bash
if grep -Fq "Command failed at line" "$TEST_ROOT/err"; then
  record "expected deploy absence probes stay quiet" fail
else
  record "expected deploy absence probes stay quiet" pass
fi
```

- [x] **Step 2: Run the operational suite and verify RED**

Run:

```bash
bash scripts/tests/operations_test.sh
```

Expected: `expected deploy absence probes stay quiet` fails.

- [x] **Step 3: Disable the inherited ERR trap in both expected lookups**

Change the stack command substitution at `scripts/deploy.sh:67` to:

```bash
if stack_status=$(trap - ERR; aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>&1); then
```

Change the cluster command substitution at `scripts/deploy.sh:117` to:

```bash
if cluster_status=$(trap - ERR; aws eks describe-cluster \
  --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.status' --output text 2>&1); then
```

- [x] **Step 4: Run the operational suite and verify GREEN**

Run:

```bash
bash scripts/tests/operations_test.sh
```

Expected: `200 passed, 0 failed`, including `expected deploy absence probes stay quiet`.

- [x] **Step 5: Commit the diagnostic fix**

```bash
git add scripts/deploy.sh scripts/tests/operations_test.sh
git commit -m "fix: silence expected deploy stack probe"
```

### Task 5: Full verification

**Files:**
- Verify: `scripts/tests/operations_test.sh`
- Verify: `scripts/preflight.sh`
- Verify: `scripts/render-cluster-config.sh`
- Verify: `scripts/deploy.sh`

- [x] **Step 1: Check formatting and the complete diff**

Run:

```bash
git diff --check main...HEAD
git diff --stat main...HEAD
git status --short
```

Expected: no whitespace errors and only the design, plan, tests, and three target scripts changed.

- [x] **Step 2: Run the complete verification suite**

Run:

```bash
env GOCACHE=/tmp/twc-lab-debug-go-cache make verify
```

Expected: exit 0, all Go tests and vet checks pass, Helm chart render contract passes, shell syntax passes, and all operational tests report zero failures.

- [x] **Step 3: Verify the corrected query against the live recorded subnets**

Run:

```bash
aws ec2 describe-subnets \
  --region us-east-1 \
  --subnet-ids subnet-04b0854e00fe42c30 subnet-037f8d9ec481b8266 \
  --query 'Subnets[].[AvailabilityZone,SubnetId]' \
  --output text
```

Expected: exactly two lines, one for `us-east-1a` and one for `us-east-1b`.

- [x] **Step 4: Commit any final plan tracking updates**

```bash
git add docs/superpowers/plans/2026-07-22-subnet-availability-zone-discovery.md
git commit -m "docs: record subnet discovery implementation"
```
