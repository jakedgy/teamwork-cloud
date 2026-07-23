# EKS Teamwork Cloud Deployment Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a redistributable Teamwork Cloud-shaped deployment lab on EKS Auto Mode with real Cassandra, ZooKeeper, and Artemis dependencies and an explicitly simulated admin/licensing UI.

**Architecture:** A small Go service serves the read-only UI and performs protocol-level dependency checks. A clean-room Helm chart deploys the service and three single-node dependencies; ingress-nginx exposes it through an EKS Auto Mode NLB. Bash scripts and `eksctl` manage either a dedicated public VPC or validated existing public subnets.

**Tech Stack:** Go 1.26, `net/http`, `gocql`, HTML/CSS/JavaScript, Helm 3, Kubernetes, EKS Auto Mode, `eksctl`, AWS CLI, CloudFormation, ingress-nginx, Docker, Make, GitHub Actions.

---

## File map

```text
cmd/twc-lab/main.go                         Process wiring and shutdown
internal/config/config.go                   Environment parsing
internal/config/config_test.go              Configuration tests
internal/health/types.go                    Checker and result contracts
internal/health/monitor.go                  Periodic health aggregation
internal/health/monitor_test.go             Aggregation and timeout tests
internal/health/cassandra.go                CQL checker
internal/health/zookeeper.go                ZooKeeper ruok checker
internal/health/artemis.go                  STOMP checker
internal/health/protocol_test.go             Local protocol-server tests
internal/web/server.go                      Routes, API, embedded assets
internal/web/server_test.go                 Route and disclosure tests
internal/web/templates/*.html               Simulator pages
internal/web/static/*                       Dashboard CSS and JavaScript
Dockerfile                                  Non-root image
charts/twc-lab/                             Clean-room workload chart
cluster/vpc-public.yaml                     Managed public VPC
cluster/ingress-nginx-values.yaml            Auto Mode NLB values
scripts/lib.sh                              Safe shared operations
scripts/preflight.sh                        AWS and subnet validation
scripts/deploy.sh                           Deployment workflow
scripts/status.sh                           Status and explanation
scripts/demo-failure.sh                     Allowlisted failure
scripts/demo-restore.sh                     Recovery
scripts/destroy.sh                          Scoped teardown
scripts/render-cluster-config.sh            eksctl config renderer
scripts/tests/operations_test.sh             Offline script tests
Makefile                                    Stable command surface
README.md                                   Walkthrough and warnings
docs/architecture.md                       Real/simulated boundaries and data flow
docs/demo-script.md                        Short hosted-demo presentation script
docs/runbook.md                            Deploy, inspect, recover, and destroy guide
.github/workflows/*.yml                     Verify, publish, EKS smoke
```

Do not copy files from the downloaded vendor chart or container archives.

### Task 1: Bootstrap configuration and process lifecycle

**Files:**
- Create: `go.mod`
- Create: `cmd/twc-lab/main.go`
- Create: `internal/config/config.go`
- Create: `internal/config/config_test.go`

- [ ] **Step 1: Initialize the module**

```bash
go mod init github.com/jakedgy/teamwork-cloud
go get github.com/gocql/gocql@v1.7.0
```

Expected: `go.mod` names the repository module and `go.sum` records `gocql`.

- [ ] **Step 2: Write failing configuration tests**

Test `config.FromLookup` with an empty lookup and require:

```go
Config{
    ListenAddr: ":8080", CheckInterval: 10*time.Second,
    CheckTimeout: 3*time.Second,
    CassandraHost: "twc-lab-cassandra:9042",
    ZooKeeperHost: "twc-lab-zookeeper:2181",
    ArtemisHost: "twc-lab-artemis:61616",
    ArtemisUser: "artemis", ArtemisPassword: "",
    ClusterName: "twc-lab", AWSRegion: "us-east-1",
}
```

Add cases for valid duration and endpoint overrides. Require zero, negative, and malformed durations to return an error containing the environment variable name.

- [ ] **Step 3: Run the failing tests**

Run: `go test ./internal/config -v`

Expected: FAIL because `Config` and `FromLookup` do not exist.

- [ ] **Step 4: Implement minimal configuration and process lifecycle**

Implement:

```go
type Config struct {
    ListenAddr string
    CheckInterval, CheckTimeout time.Duration
    CassandraHost, ZooKeeperHost, ArtemisHost string
    ArtemisUser, ArtemisPassword string
    ClusterName, AWSRegion string
}
func FromEnv() (Config, error) { return FromLookup(os.LookupEnv) }
func FromLookup(func(string) (string, bool)) (Config, error)
```

Parse with `time.ParseDuration`, reject durations `<= 0`, and never log the password. Start an `http.Server` with a temporary 503 handler. Handle `SIGINT` and `SIGTERM` using a five-second shutdown context.

- [ ] **Step 5: Format, test, and commit**

```bash
gofmt -w cmd/twc-lab internal/config
go test ./...
git add go.mod go.sum cmd/twc-lab internal/config
git commit -m "feat: bootstrap simulator service"
```

Expected: PASS and one focused commit.

### Task 2: Build concurrent health aggregation

**Files:**
- Create: `internal/health/types.go`
- Create: `internal/health/monitor.go`
- Create: `internal/health/monitor_test.go`

- [ ] **Step 1: Write failing monitor tests**

Define a fake checker with error and delay controls. Test concurrent completion, successful `ready` state, failed `unavailable` state, timeout text `check timed out`, preservation of `LastSuccessAt`, and name-sorted defensive copies from `Snapshot()`.

Use these exact contracts in the tests:

```go
type Checker interface {
    Name() string
    Endpoint() string
    Check(context.Context) error
}
type Status string
const (
    StatusStarting Status = "starting"
    StatusReady Status = "ready"
    StatusUnavailable Status = "unavailable"
)
type Result struct {
    Name string `json:"name"`
    Endpoint string `json:"endpoint"`
    Status Status `json:"status"`
    CheckedAt time.Time `json:"checkedAt"`
    LastSuccessAt time.Time `json:"lastSuccessAt,omitempty"`
    LatencyMillis int64 `json:"latencyMillis"`
    Error string `json:"error,omitempty"`
}
```

- [ ] **Step 2: Run tests and observe failure**

Run: `go test ./internal/health -run TestMonitor -v`

Expected: FAIL on undefined health types.

- [ ] **Step 3: Implement monitor behavior**

`NewMonitor(checkers, timeout)` initializes `starting` results. `CheckNow` creates one timeout context per checker, checks through a `sync.WaitGroup`, and updates a mutex-protected map. Limit safe errors to 160 printable characters. `Run(ctx, interval)` checks immediately and on every tick until canceled.

- [ ] **Step 4: Verify and commit**

```bash
gofmt -w internal/health
go test -race ./internal/health -v
git add internal/health
git commit -m "feat: monitor dependency health"
```

Expected: PASS with no race report.

### Task 3: Add real protocol checkers

**Files:**
- Create: `internal/health/cassandra.go`
- Create: `internal/health/zookeeper.go`
- Create: `internal/health/artemis.go`
- Create: `internal/health/protocol_test.go`

- [ ] **Step 1: Write failing protocol tests**

Use local `net.Listener` servers. ZooKeeper must receive `ruok` and return `imok`. Artemis must receive a NUL-terminated STOMP `CONNECT` frame and return:

```text
CONNECTED
version:1.2

\x00
```

Test good and malformed responses, refusal, cancellation, and password redaction. For Cassandra inject:

```go
type CassandraSession interface { Query(string, ...any) CassandraQuery; Close() }
type CassandraQuery interface { Exec() error }
```

Require `SELECT release_version FROM system.local` and a closed session.

- [ ] **Step 2: Verify failure**

Run: `go test ./internal/health -run 'Test(Cassandra|ZooKeeper|Artemis)' -v`

Expected: FAIL on missing constructors.

- [ ] **Step 3: Implement minimal protocol clients**

Use `net.Dialer.DialContext` and context-derived deadlines for ZooKeeper and Artemis. Read at most 8 KiB from Artemis and return fixed errors rather than broker response bodies. Back Cassandra with `gocql.NewCluster`, one host, a three-second connection timeout, and the harmless query.

- [ ] **Step 4: Verify and commit**

```bash
gofmt -w internal/health
go test -race ./internal/health -v
git add internal/health go.mod go.sum
git commit -m "feat: check real service protocols"
```

Expected: PASS.

### Task 4: Implement the simulated admin experience

**Files:**
- Create: `internal/web/server.go`
- Create: `internal/web/server_test.go`
- Create: `internal/web/templates/layout.html`
- Create: `internal/web/templates/webapp.html`
- Create: `internal/web/templates/authentication.html`
- Create: `internal/web/templates/admin.html`
- Create: `internal/web/templates/license.html`
- Create: `internal/web/static/styles.css`
- Create: `internal/web/static/app.js`
- Modify: `cmd/twc-lab/main.go`

- [ ] **Step 1: Write failing route and disclosure tests**

Using `httptest`, require `/` to redirect to `/webapp`; the four specified pages to return 200; every page to contain `Simulated product layer`; the license page to contain `Not activated`, `FlexNet`, and `DSLS` but no `<input`; JSON health to be sorted; liveness/readiness to remain 200 during dependency failure; and no password or stack trace in any response.

- [ ] **Step 2: Verify failure**

Run: `go test ./internal/web -v`

Expected: FAIL because `web.New` is missing.

- [ ] **Step 3: Implement the server API**

Use these contracts:

```go
type Snapshotter interface { Snapshot() []health.Result }
type Metadata struct { ClusterName string `json:"clusterName"`; AWSRegion string `json:"awsRegion"` }
func New(Snapshotter, Metadata) (http.Handler, error)
```

Embed templates and static files. Add CSP `default-src 'self'`, `nosniff`, and no-referrer headers. Return `{cluster, region, checkedAt, services}` from `/api/health`. `/healthz` checks process liveness; `/readyz` checks server initialization, not dependency health.

- [ ] **Step 4: Build the approved visual experience**

Use high-contrast navy cards for real services and amber cards for the simulator/license boundary. Include visible focus states and semantic headings. Never use vendor logos. JavaScript fetches `/api/health` immediately and every ten seconds and inserts errors only with `textContent`.

- [ ] **Step 5: Wire monitor and graceful shutdown**

Construct all checkers from `config.Config`, start `Monitor.Run`, and pass it to `web.New`. Cancel the monitor before the five-second HTTP shutdown wait.

- [ ] **Step 6: Verify and commit**

```bash
gofmt -w cmd/twc-lab internal/web
go test -race ./...
git add cmd/twc-lab internal/web
git commit -m "feat: add simulated admin experience"
```

Expected: PASS.

### Task 5: Package and test the container

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `scripts/tests/container_test.sh`

- [ ] **Step 1: Write a failing container test**

Build `twc-lab:test`, require image user `65532:65532`, start on an ephemeral host port, wait 20 seconds for `/healthz`, require the simulator label on `/webapp`, and remove the container in a trap.

- [ ] **Step 2: Verify failure**

Run: `bash scripts/tests/container_test.sh`

Expected: FAIL because no Dockerfile exists.

- [ ] **Step 3: Implement the image**

Use `golang:1.26.5-alpine` then `gcr.io/distroless/static-debian12:nonroot`. Build with:

```dockerfile
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags="-s -w -buildid=" -o /out/twc-lab ./cmd/twc-lab
```

Set `USER 65532:65532`, `EXPOSE 8080`, and `ENTRYPOINT ["/twc-lab"]`. Ignore `.git`, `.worktrees`, `.superpowers`, `.twc-lab`, docs, and archives.

- [ ] **Step 4: Verify and commit**

```bash
bash scripts/tests/container_test.sh
git add Dockerfile .dockerignore scripts/tests/container_test.sh
git commit -m "build: package simulator container"
```

Expected: PASS.

### Task 6: Create the clean-room Helm chart

**Files:**
- Create: `charts/twc-lab/Chart.yaml`
- Create: `charts/twc-lab/values.yaml`
- Create: `charts/twc-lab/templates/_helpers.tpl`
- Create: `charts/twc-lab/templates/storageclass.yaml`
- Create: `charts/twc-lab/templates/secret.yaml`
- Create: `charts/twc-lab/templates/cassandra.yaml`
- Create: `charts/twc-lab/templates/zookeeper.yaml`
- Create: `charts/twc-lab/templates/artemis.yaml`
- Create: `charts/twc-lab/templates/simulator.yaml`
- Create: `charts/twc-lab/templates/ingress.yaml`
- Create: `charts/twc-lab/templates/NOTES.txt`
- Create: `charts/twc-lab/tests/render_test.sh`
- Create: `cluster/ingress-nginx-values.yaml`

- [ ] **Step 1: Write failing render assertions**

Run `helm lint` and `helm template` into a temporary file. Require three named StatefulSets, simulator Deployment/Service, PVC sizes 8/2/2 GiB, ports 9042/2181/61616/8080, three ingress prefixes, non-root simulator security, and no ClusterRole, MetalLB, KEDA, FlexNet, vendor image, or `latest` tag.

- [ ] **Step 2: Verify failure**

Run: `bash charts/twc-lab/tests/render_test.sh`

Expected: FAIL because the chart is absent.

- [ ] **Step 3: Add chart values and workloads**

Use chart/app version `0.1.0` and defaults:

```yaml
simulator: {image: {repository: ghcr.io/jakedgy/teamwork-cloud, tag: "0.1.0"}}
cassandra:
  image: {repository: cassandra, tag: "4.1.4"}
  resources: {requests: {cpu: "1", memory: 2Gi}, limits: {memory: 3Gi}}
  persistence: {size: 8Gi}
zookeeper:
  image: {repository: zookeeper, tag: "3.9.2"}
  resources: {requests: {cpu: 250m, memory: 512Mi}, limits: {memory: 1Gi}}
  persistence: {size: 2Gi}
artemis:
  image: {repository: apache/activemq-artemis, tag: "2.32.0"}
  resources: {requests: {cpu: 500m, memory: 1Gi}, limits: {memory: 2Gi}}
  persistence: {size: 2Gi}
secrets: {artemisUser: artemis, artemisPassword: ""}
```

Require a non-empty password. Create `auto-ebs` with `ebs.csi.eks.amazonaws.com`, `gp3`, `WaitForFirstConsumer`, and reclaim policy Delete. Add headless Services, PVC templates, protocol probes, and the design resource requests.

- [ ] **Step 4: Add simulator, ingress, and NLB values**

Inject DNS endpoints, Secret keys, cluster, and region. Add liveness/readiness. Ingress class is `nginx`, has no host, applies cookie affinity, and routes approved paths. ingress-nginx values specify Service type LoadBalancer, `loadBalancerClass: eks.amazonaws.com/nlb`, internet-facing scheme, and IP targets.

- [ ] **Step 5: Verify and commit**

```bash
bash charts/twc-lab/tests/render_test.sh
git add charts cluster/ingress-nginx-values.yaml
git commit -m "feat: add clean-room Kubernetes chart"
```

Expected: PASS.

### Task 7: Implement safe network and lifecycle operations

**Files:**
- Create: `cluster/vpc-public.yaml`
- Create: `scripts/lib.sh`
- Create: `scripts/preflight.sh`
- Create: `scripts/render-cluster-config.sh`
- Create: `scripts/deploy.sh`
- Create: `scripts/status.sh`
- Create: `scripts/demo-failure.sh`
- Create: `scripts/demo-restore.sh`
- Create: `scripts/destroy.sh`
- Create: `scripts/tests/operations_test.sh`

- [ ] **Step 1: Write failing offline tests with fake CLIs**

Put fake `aws`, `eksctl`, `kubectl`, and `helm` commands first on a temporary PATH and record calls. Require invalid modes to fail before AWS; existing mode to require one VPC and two subnets; single-AZ, low-IP, missing-public-IP, missing-IGW-route, and missing-role-tag cases to fail; managed deployment call order; existing mode to avoid CloudFormation mutations; service-name allowlisting; account mismatch refusal; NLB deletion before cluster deletion; and VPC deletion only for managed mode.

- [ ] **Step 2: Verify failure**

Run: `bash scripts/tests/operations_test.sh`

Expected: FAIL because operations are absent.

- [ ] **Step 3: Implement shared safety and managed VPC**

`lib.sh` defines strict-mode validation, fixed-key state parsing without `source`, confirmation, and diagnostics. State is `.twc-lab/state.env` mode 0600. Allowed keys are account, region, cluster, mode, VPC, subnets, stack, failed service, and NLB hostname.

CloudFormation creates `10.42.0.0/16`, two `/20` public subnets in different AZs, IGW, route table/default route, public-IP assignment, `kubernetes.io/role/elb=1`, and cluster ownership tags. Output VPC ID and comma-separated subnet IDs.

- [ ] **Step 4: Implement preflight and eksctl rendering**

Default to `us-east-1`, `twc-lab`, and managed mode. Verify commands, caller, collision, and state identity. Existing mode verifies exact VPC membership, two AZs, 16 available IPs each, public-IP mapping, IGW default route, and role tag without modifying anything.

Render `.twc-lab/cluster.yaml` with explicit public subnets and:

```yaml
autoModeConfig:
  enabled: true
  nodePools: [general-purpose, system]
```

- [ ] **Step 5: Implement deploy and status**

Managed mode creates/reuses only its tagged stack. Generate a 32-character password into `.twc-lab/secrets.yaml` mode 0600. Create cluster, update kubeconfig, install ingress-nginx chart `4.13.3`, install the lab, wait for rollouts and the NLB hostname, then print three URLs. `status.sh` prints account/network ownership, Kubernetes resources, releases, URL, and health; `JSON=1` emits one JSON object.

- [ ] **Step 6: Implement failure, restore, and teardown**

Allow only Cassandra, ZooKeeper, or Artemis. Confirm before scaling to zero and record the service. Restore to one and wait. Teardown validates account, uninstalls releases, waits for NLB deletion, deletes cluster, checks tagged ELB/EBS residuals, and deletes the managed VPC stack only after success. Existing VPC resources are never changed or deleted. Preserve state on partial failure.

- [ ] **Step 7: Verify and commit**

```bash
bash -n scripts/*.sh scripts/tests/*.sh
bash scripts/tests/operations_test.sh
git add cluster/vpc-public.yaml scripts
git commit -m "feat: automate EKS lab lifecycle"
```

Expected: PASS without real AWS calls.

### Task 8: Add Make, documentation, and CI

**Files:**
- Create: `Makefile`
- Create: `README.md`
- Create: `docs/architecture.md`
- Create: `docs/demo-script.md`
- Create: `docs/runbook.md`
- Create: `.github/workflows/verify.yml`
- Create: `.github/workflows/image.yml`
- Create: `.github/workflows/eks-smoke.yml`
- Modify: `.gitignore`

- [ ] **Step 1: Add stable commands and ignored state**

Make targets call one matching script. `verify` runs Go race tests/vet, Helm render tests, offline operation tests, and shell syntax. Add `.twc-lab/`, `coverage.out`, and `*.local.yaml` to `.gitignore`.

- [ ] **Step 2: Write the README as the five-minute front door**

Include what is real/simulated, cost and HTTP warnings, prerequisites, managed and existing VPC paths, UI tour, failure/recovery, architecture, troubleshooting, cleanup, and reference mapping. Quick start is:

```bash
make preflight
make deploy
make status
```

Existing mode shows `NETWORK_MODE=existing VPC_ID=vpc-0123456789abcdef0 PUBLIC_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0fedcba9876543210 AWS_REGION=us-east-1 make deploy` and explains the required subnet tag.

- [ ] **Step 3: Write focused supporting guides**

`docs/architecture.md` maps the original Teamwork Cloud example to this lab, explains the browser → NLB → ingress-nginx → simulator request path, describes the three real dependency protocols, and marks every simulated boundary.

`docs/demo-script.md` is a concise presentation flow: open `/webapp`, show the license boundary, inspect all-green health, run `make demo-failure SERVICE=artemis`, watch the card fail, restore it, and close with `make destroy`. Include expected observable results and a reminder that the UI is simulated.

`docs/runbook.md` contains preflight interpretation, managed and existing VPC deployment, status commands, Kubernetes diagnostics, common NLB/PVC/Pod failures, safe recovery, residual-resource checks, and teardown. Link all three guides prominently from the README.

- [ ] **Step 4: Add free verification and image workflows**

`verify.yml` uses Go 1.26.5, Helm 3.15.4, shellcheck, `make verify`, Docker build, non-root inspection, and Trivy with no AWS credentials. `image.yml` publishes amd64/arm64 GHCR images only for version tags or manual dispatch, tagged by version and SHA, never `latest`.

- [ ] **Step 5: Add manual paid smoke workflow**

Use OIDC, unique `twc-lab-smoke-${{ github.run_id }}`, six-hour timeout, deploy/status, Artemis failure/restore, and `if: always()` teardown. Document `AWS_ROLE_ARN` and `AWS_REGION` requirements.

- [ ] **Step 6: Verify and commit**

```bash
make verify
docker build -t twc-lab:test .
git diff --check
git add .gitignore Makefile README.md docs/architecture.md docs/demo-script.md docs/runbook.md .github
git commit -m "docs: add deployment workflow and automation"
```

Expected: all free checks PASS.

### Task 9: Validate on EKS, pin digests, and close the branch

**Files:**
- Modify: `charts/twc-lab/values.yaml`
- Modify: `README.md`
- Create: `docs/validation/eks-smoke.md`
- Modify only files implicated by verification failures.

- [ ] **Step 1: Run free verification**

```bash
make verify
bash scripts/tests/container_test.sh
git status --short
```

Expected: PASS and clean status.

- [ ] **Step 2: Run non-mutating AWS preflight**

Run: `AWS_REGION=us-east-1 CLUSTER_NAME=twc-lab make preflight`

Expected: identity and intended managed network are printed; no resources are created.

- [ ] **Step 3: Obtain explicit approval for paid deployment**

Show the user the resolved account, region, and resources. Do not run deploy until they approve the cost-bearing EKS test.

- [ ] **Step 4: Deploy and demonstrate health transitions**

```bash
AWS_REGION=us-east-1 CLUSTER_NAME=twc-lab make deploy
make status
CONFIRM=1 make demo-failure SERVICE=artemis
sleep 20
make status
make demo-restore
make status
```

Expected: all ready, then Artemis unavailable, then all ready.

- [ ] **Step 5: Pin immutable runtime image IDs**

Capture `.status.containerStatuses[].imageID` for every Pod. Replace dependency tag references with validated `tag@sha256:digest` references, redeploy, and record digests plus ingress chart version in `docs/validation/eks-smoke.md`.

- [ ] **Step 6: Verify routes and destroy**

Request `/webapp`, `/authentication`, `/admin`, `/admin/license`, and `/api/health`; record codes/times. Run `CONFIRM=1 make destroy`, then require `aws eks describe-cluster` to return `ResourceNotFoundException` and residual ELB/EBS checks to be empty.

- [ ] **Step 7: Commit validation evidence**

```bash
git add charts/twc-lab/values.yaml README.md docs/validation/eks-smoke.md
git commit -m "test: validate deployment on EKS Auto Mode"
```

- [ ] **Step 8: Run final security and correctness checks**

```bash
make verify
bash scripts/tests/container_test.sh
go test -race -coverprofile=coverage.out ./...
git diff --check
find . -type f \( -name '*.war' -o -name '*.zip' -o -name '*.p12' -o -name '*.key' \) -print
git status --short
```

Expected: checks PASS, no forbidden artifacts are found, and status is clean.

- [ ] **Step 9: Request review and prepare handoff**

Use `superpowers:requesting-code-review`, fix verified findings, rerun checks, then use `superpowers:finishing-a-development-branch`. Do not merge or push without user instruction.

### Follow-on: Add a VS Code CodeTour

After the implementation paths and EKS validation evidence are stable, create `.tours/teamwork-cloud-eks.tour` and `.vscode/extensions.json`. Recommend `vsls-contrib.codetour` and guide readers through: project framing in `README.md`; managed VPC resources; rendered `eksctl` inputs; ingress-nginx NLB values; Helm dependency workloads; Go protocol checkers; the health API/UI; failure and recovery scripts; and scoped teardown. Every tour step must explain why the file exists and link back to the longer architecture or runbook section rather than duplicating it.
