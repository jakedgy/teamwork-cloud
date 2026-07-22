# EKS Teamwork Cloud Deployment Lab Design

**Date:** 2026-07-22  
**Status:** Approved for implementation planning

## Summary

Build a small, public, redistributable deployment lab inspired by the Teamwork Cloud 2024x Refresh1 Kubernetes testing example. The lab will run on Amazon EKS Auto Mode and preserve the useful infrastructure shape of the reference deployment while replacing unavailable proprietary Teamwork Cloud binaries and web applications with an explicitly labeled simulator.

The result must support two uses:

1. The repository owner deploys one hosted instance and sends a friend its AWS load-balancer URL.
2. A friend clones the repository, authenticates to their own AWS account, and deploys an independent instance.

This is a learning and demonstration environment, not Teamwork Cloud software and not a production architecture.

## Context

The reference deployment includes Teamwork Cloud, Web Application Platform applications, Cassandra, ZooKeeper, Apache ActiveMQ Artemis, ingress-nginx, MetalLB, KEDA, local persistent volumes, and multiple replicas. Its default chart is designed around a comparatively large, self-managed Kubernetes cluster.

The official Teamwork Cloud and Web Application Platform packages require authenticated access to Dassault Systèmes software media. They are not available for this project. The downloaded chart and container examples may be inspected privately to understand topology, ports, routes, and configuration, but their contents will not be copied into the public repository.

## Goals

- Create and remove an EKS Auto Mode cluster with readable `eksctl` configuration and Make targets.
- Support both a repository-managed public VPC and an explicitly supplied existing public VPC.
- Run real, single-replica Cassandra, ZooKeeper, and Artemis services.
- Expose the lab through ingress-nginx and an AWS Network Load Balancer.
- Provide a polished, read-only simulator at familiar paths such as `/webapp`, `/authentication`, and `/admin`.
- Show live dependency health and make dependency failure and recovery visible.
- Explain which parts are real, which are simulated, and how requests flow through the stack.
- Make the default deployment consumable from public container registries without requiring ECR.
- Provide reliable preflight, deployment, status, demonstration, restore, verification, and teardown commands.
- Warn clearly about AWS charges and confirm cleanup as far as the available APIs allow.

## Non-goals

- Running or emulating proprietary Teamwork Cloud protocols, storage behavior, client connectivity, collaboration, or licensing.
- Copying the exact Teamwork Cloud user interface or presenting the simulator as a Dassault Systèmes product.
- Including vendor binaries, WAR files, license files, installation archives, or vendor chart contents.
- Production readiness, high availability, autoscaling, disaster recovery, hardening, or performance testing.
- MetalLB, KEDA, Collaborator, reports, simulation, OSLC, document export, or resource-usage-map services.
- A custom domain, Route 53, TLS, ACM, or certificate management in version 1.
- Automatic paid EKS deployments from pull-request CI.

## Architecture

The request path is:

```text
Browser
  -> AWS-generated Network Load Balancer hostname over HTTP
  -> ingress-nginx controller
  -> twc-lab simulator Service
  -> simulator UI and read-only health API
```

The simulator connects internally to:

```text
simulator -> Cassandra on CQL port 9042
simulator -> ZooKeeper on client port 2181
simulator -> Artemis on broker port 61616
```

EKS Auto Mode manages cluster compute, networking integration, and AWS load-balancer provisioning. The ingress-nginx controller is installed from its upstream Helm chart. Its Kubernetes Service uses the EKS Auto Mode Network Load Balancer class. No separately installed AWS Load Balancer Controller or MetalLB deployment is required.

Ingress has no hostname restriction in version 1, allowing the generated AWS load-balancer hostname to work directly. Paths use prefix matching.

## Repository Boundaries

```text
app/                       Go simulator and embedded static UI
charts/twc-lab/            Helm chart for the simulator and dependencies
cluster/                   eksctl EKS Auto Mode configuration
cluster/vpc-public.yaml    Small CloudFormation template for managed networking
scripts/                   Operational command implementations
docs/                      Architecture and usage explanations
.github/workflows/         Pull-request verification and image publication
Makefile                    Stable user-facing command interface
```

Generated files, credentials, local values, visual-companion artifacts, and downloaded vendor materials are excluded through `.gitignore`.

## Infrastructure Components

### EKS Auto Mode

- Created by `eksctl`; Terraform and CDK are not part of version 1.
- Default cluster name: `twc-lab`.
- Default AWS region: `us-east-2`, overridable through `AWS_REGION`.
- No self-managed node group is defined.
- The configuration enables EKS Auto Mode compute and uses its general-purpose node pool.
- The deploy workflow records the selected cluster name and region in a gitignored local state file so later commands target the same cluster.

### VPC and public subnets

The deployment supports two explicit network modes.

In the default `managed` mode, the repository creates a dedicated CloudFormation VPC stack before running `eksctl`. The stack contains:

- One IPv4 VPC.
- Two public subnets in different Availability Zones.
- An internet gateway and a default route from both subnets.
- Public IPv4 assignment on instance launch.
- The `kubernetes.io/role/elb=1` tag required for an internet-facing EKS Auto Mode load balancer.
- Repository and cluster ownership tags used for validation and cleanup.

The VPC deliberately has no private subnets or NAT gateway. EKS Auto Mode nodes and Pods run in the public subnets, while security groups continue to control inbound access. This is a cost-conscious prototype trade-off and is documented as unsuitable for production.

In `existing` mode, the caller supplies one VPC ID and at least two public subnet IDs in different Availability Zones. The workflow verifies that all subnets belong to that VPC, have sufficient available addresses, assign public IPv4 addresses, route through an internet gateway, and carry the public load-balancer role tag. It does not create, delete, route, or retag the existing network. If validation fails, it reports the exact requirement and stops before creating the cluster.

The selected mode and exact VPC and subnet IDs are recorded in local state. Teardown deletes the VPC stack only when that state proves the repository created it.

### ingress-nginx and AWS NLB

- ingress-nginx is installed separately from the application chart using a pinned upstream chart version.
- Its controller Service is `LoadBalancer` and specifies the EKS Auto Mode NLB load-balancer class.
- The deployment waits for the Service to receive an AWS hostname before reporting success.
- The public endpoint is HTTP-only in version 1.

### Cassandra

- A real single-replica StatefulSet.
- A maintained Cassandra 4.1 image is pinned to an explicit patch version and immutable digest during implementation; `latest` is prohibited.
- Uses an EBS-backed 8 GiB persistent volume.
- Requests 1 CPU and 2 GiB memory by default; CI-small values may lower these requests for render-only tests.
- Readiness verifies that CQL is accepting queries.

### ZooKeeper

- A real single-replica StatefulSet.
- A maintained 3.9 image is pinned to an explicit patch version and immutable digest during implementation.
- Uses an EBS-backed 2 GiB persistent volume.
- Requests 250 millicores and 512 MiB memory by default.
- Readiness uses the ZooKeeper `ruok`/`imok` health exchange.

### Apache ActiveMQ Artemis

- A real single-replica StatefulSet.
- A maintained 2.x image is pinned to an explicit patch version and immutable digest during implementation.
- Uses an EBS-backed 2 GiB persistent volume.
- Requests 500 millicores and 1 GiB memory by default.
- Readiness verifies that the broker port accepts a protocol connection.

### Simulator

- A single statically compiled Go binary in a minimal non-root container.
- Embeds HTML, CSS, and browser JavaScript in the binary.
- Requests 100 millicores and 128 MiB memory by default.
- Has no Kubernetes RBAC permissions, AWS credentials, or mutation endpoints.
- Receives internal dependency addresses and demo broker credentials through Kubernetes configuration.
- Publishes an unprivileged HTTP port, defaulting to 8080.

## Simulator Experience

The simulator uses its own “Teamwork Cloud Kubernetes Deployment Lab” identity and displays a persistent “Simulated product layer” label.

Routes are:

- `/` redirects to `/webapp`.
- `/webapp` introduces the deployment lab and links to the admin dashboard.
- `/authentication` explains that authentication is simulated and provides a no-credential continuation to the read-only dashboard.
- `/admin` displays dependency state, request flow, cluster context supplied at deployment time, and demo commands.
- `/admin/license` displays “Not activated” and explains that Teamwork Cloud binaries and a FlexNet or DSLS license are absent. It does not offer a fake activation workflow.
- `/api/health` returns the current dependency checks as JSON.
- `/healthz` reports simulator-process liveness without depending on external services.
- `/readyz` reports readiness after the HTTP server and health-check loop have initialized; individual dependency failures do not make the simulator unready.

The UI refreshes `/api/health` every ten seconds. A dependency card includes state, last successful check, last attempt, latency, and a short safe error summary. Browser responses never expose credentials, internal stack traces, or AWS metadata.

The dashboard is public and read-only. This is acceptable for version 1 because it contains no private data and performs no mutations. The README warns users not to add real secrets or data to the lab.

## Dependency Health Checks

The simulator checks dependencies in a background loop with per-check timeouts and bounded concurrency.

- Cassandra: establish a CQL session and query a harmless value from `system.local`.
- ZooKeeper: send `ruok` and require `imok`.
- Artemis: establish an authenticated broker protocol connection and close it without sending a message.

Each checker implements one small interface so it can be unit-tested independently. Startup dependency failures are expected: the simulator starts, reports dependencies as unavailable, and updates automatically as they become ready.

## Deployment Interface

The stable commands are:

```bash
make preflight
make deploy
make status
make demo-failure SERVICE=artemis
make demo-restore
make verify
make destroy
```

### `make preflight`

Checks:

- Required local commands: AWS CLI, `eksctl`, `kubectl`, Helm, Make, and Docker only when doing a local image build.
- Working AWS authentication and caller identity.
- Selected region availability and required EKS/IAM/EC2/ELB permissions through non-destructive checks where possible.
- Whether the selected cluster name already exists.
- That local state does not point to a different account, region, or cluster.
- In `managed` mode, whether the intended CloudFormation VPC stack name is available or already belongs to this repository deployment.
- In `existing` mode, the supplied VPC and subnet ownership, Availability Zones, public-IP assignment, internet-gateway routing, free addresses, and required `kubernetes.io/role/elb=1` tags.

### `make deploy`

1. Runs preflight.
2. In `managed` mode, creates the dedicated public VPC stack and records its VPC and subnet outputs; in `existing` mode, records the validated supplied IDs without modifying them.
3. Renders the `eksctl` configuration with the selected public subnets.
4. Creates the EKS Auto Mode cluster unless the selected cluster already exists and matches local state.
5. Updates kubeconfig.
6. Installs or upgrades ingress-nginx with the repository's pinned values.
7. Generates demo-only internal credentials into a permission-restricted, gitignored values file.
8. Installs or upgrades the `twc-lab` Helm release.
9. Waits for dependency and simulator workloads to become ready with bounded timeouts.
10. Waits for the NLB hostname.
11. Prints the `/webapp`, `/admin`, and `/admin/license` URLs.

The operation is idempotent for a matching repository-managed cluster. It refuses to adopt or modify an unrelated pre-existing cluster with the same name.

### `make status`

Prints the selected account, region, cluster, Helm releases, pods, persistent claims, ingress service hostname, simulator health response, and a short explanation of each layer.

It also prints the network mode and exact VPC and subnet IDs, clearly marking an existing VPC as externally owned.

### Failure demonstration

`make demo-failure SERVICE=<name>` accepts only `cassandra`, `zookeeper`, or `artemis`. It scales the selected workload to zero after showing the target and requiring an interactive confirmation, unless `CONFIRM=1` is supplied for scripted use. It records the changed service in local state.

`make demo-restore` restores the recorded service to one replica and waits for readiness. It is safe to run when no failure is active.

### `make destroy`

1. Resolves the exact account, region, and cluster from local state and asks for confirmation.
2. Uninstalls the application and ingress releases.
3. Waits for the NLB resource to disappear.
4. Deletes the EKS cluster through `eksctl`.
5. Checks for known load balancers, volumes, and related resources bearing the cluster tags.
6. In `managed` mode only, deletes the recorded CloudFormation VPC stack after cluster-owned resources are gone.
7. Reports anything it cannot confirm as removed and preserves local state when cleanup is incomplete.

The command does not use broad name patterns or delete resources outside the recorded cluster scope. In `existing` mode it never deletes or modifies the supplied VPC, subnets, routes, internet gateway, or subnet tags.

## Container Distribution

GitHub Actions builds the simulator container and publishes it publicly to GitHub Container Registry for repository tags and the default branch. The Helm chart defaults to a pinned release tag, not `latest`.

Cloners can deploy using the published image without Docker or ECR. A documented override allows a user to supply another image repository and tag. Local image development is supported separately and is not part of the default EKS deployment path.

## Error Handling and Diagnostics

- Shell scripts use strict error handling, explicit phases, bounded waits, and actionable failure messages.
- A failed deployment preserves the cluster and workloads for inspection.
- On failure, scripts print relevant pod status, recent events, workload descriptions, and selected container logs while redacting generated credentials.
- Health-check errors are summarized for the browser and logged in more detail by the simulator without logging credentials.
- Partial restore or teardown is reported as incomplete rather than declared successful.
- Commands validate local state against AWS caller identity before making changes.

## Security Boundary

- The public UI is read-only and contains no infrastructure mutation endpoints.
- The simulator ServiceAccount has no additional RBAC bindings.
- No AWS credentials are mounted into application pods.
- Demo-only broker credentials are generated locally, stored in a gitignored permission-restricted values file, and placed in a Kubernetes Secret.
- No license entry form or secret collection UI exists.
- No vendor files or generated certificates are committed.
- HTTP is an explicit prototype trade-off; users are warned not to enter sensitive information.

## Testing and Continuous Integration

### Application tests

- Unit tests for every route and redirect.
- Unit tests for health aggregation, timeout behavior, stale results, and safe error serialization.
- Protocol-checker tests using local fakes or test servers.
- Static UI checks for the simulated-product label and license-boundary language.

### Chart and script tests

- `helm lint` and `helm template` for default and CI-small values.
- Assertions over rendered workload kinds, ports, probes, storage, Services, Ingress paths, security contexts, and absence of privileged RBAC.
- Shell static analysis and formatting checks.
- Tests for service-name allowlisting and local-state mismatch protection.

### Container checks

- Reproducible multi-stage build.
- Non-root runtime assertion.
- Vulnerability scan with a documented policy for failing severities and time-bounded exceptions.

### EKS smoke test

An opt-in manual GitHub Actions workflow deploys, probes, demonstrates one failure and recovery, and destroys a uniquely named EKS cluster. It requires explicitly configured AWS credentials and manual invocation. It is not run on pull requests or ordinary pushes.

## Documentation

The README leads with:

1. What the project demonstrates.
2. What is real and what is simulated.
3. AWS cost and HTTP-only warnings.
4. Prerequisites.
5. The default managed-VPC deployment path.
6. The existing-VPC deployment path and validation requirements.
7. The browser walkthrough.
8. Failure and recovery demonstration.
9. Cleanup and residual-resource checks.
10. A mapping from the original Kubernetes example to this reduced EKS design.

The explanation emphasizes that the original MetalLB role is replaced by EKS Auto Mode's NLB integration, high availability is collapsed to single replicas, and only the unavailable proprietary application layer is simulated.

## Acceptance Criteria

- From a clean AWS account with the documented prerequisites, the default command sequence produces an EKS Auto Mode deployment and prints a reachable AWS load-balancer URL.
- The default path creates two public subnets in a dedicated VPC without a NAT gateway, and teardown removes that VPC after cluster resources are gone.
- An existing-VPC deployment accepts two or more valid public subnet IDs, leaves the supplied network unchanged, and refuses invalid or untagged subnets before cluster creation.
- `/webapp`, `/authentication`, `/admin`, and `/admin/license` are reachable through ingress-nginx.
- The UI unmistakably identifies itself as a simulator.
- Cassandra, ZooKeeper, and Artemis are real running services, and the simulator reports successful protocol-level checks for each.
- Scaling one supported dependency to zero changes its dashboard state to unavailable within twenty seconds; restore returns it to healthy without redeploying the lab.
- No AWS credentials, Kubernetes permissions, vendor artifacts, or license material are present in the simulator image or browser responses.
- A friend can deploy with public images and does not need ECR or the vendor chart ZIP.
- Pull-request verification runs without AWS credentials and without creating paid infrastructure.
- Teardown removes the Helm releases, NLB, EKS cluster, and cluster-scoped persistent volumes, or reports specific residual resources that require attention.

## References

- [Teamwork Cloud 2024x Refresh1 Kubernetes deployment example](https://docs.nomagic.com/spaces/TWCloud2024xR1/pages/178163939/Deployment%2Bexample%2Bfor%2BTeamwork%2BCloud%2Bwith%2Bservices%2Bon%2BKubernetes)
- [Teamwork Cloud license management](https://docs.nomagic.com/display/TWCloud2024xR2/License%2Bmanagement)
- [Amazon EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)
- [Amazon EKS load-balancing guidance](https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html)
- [Amazon EKS Auto Mode subnet tags](https://docs.aws.amazon.com/eks/latest/userguide/tag-subnets-auto.html)
- [eksctl VPC configuration](https://docs.aws.amazon.com/eks/latest/eksctl/vpc-configuration.html)
- [ingress-nginx annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
