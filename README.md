# Teamwork Cloud Kubernetes Deployment Lab

This repository is a small, public EKS Auto Mode lab inspired by the topology of the Teamwork Cloud 2024x Refresh1 Kubernetes deployment example. It keeps the useful infrastructure shape while replacing the unavailable proprietary application layer with a clearly labeled, read-only simulator.

**Real:** Amazon EKS Auto Mode, ingress-nginx, an internet-facing AWS Network Load Balancer (NLB), and single-node Cassandra, ZooKeeper, and Apache ActiveMQ Artemis services. The dashboard checks those services using CQL, ZooKeeper `ruok`, and STOMP.

**Simulated:** Teamwork Cloud, Web Application Platform, authentication, administration, collaboration, and licensing. This is not Dassault Systèmes software and is not a production architecture.

> **Cost and security warning:** Deploying creates billable AWS resources, including an EKS cluster, load balancer, compute, and EBS volumes. The lab uses public subnets and an HTTP-only public endpoint. Never enter sensitive data, credentials, license keys, or real project data. Run `make destroy` when finished and review its residual-resource report.

## Projected cost

For a continuously running lab in `us-east-1`, budget approximately:

| Runtime | Estimated cost (USD) |
| --- | ---: |
| Hourly | **$0.40–$0.45** |
| Daily (24 hours) | **$9.60–$10.80** |
| Monthly (730 hours) | **$292–$329** |

This July 2026 estimate assumes an EKS version in standard support, three On-Demand `c6a.large` EKS Auto Mode nodes, Auto Mode management fees, public IPv4 addresses, an internet-facing NLB with light traffic, and the lab's EBS volumes. Actual cost varies with Karpenter's selected nodes, traffic and NLCU usage, storage, data transfer, Region, purchase model, and Kubernetes support tier. Destroy the lab promptly when it is not in use. See AWS pricing for [EKS](https://aws.amazon.com/eks/pricing/), [EC2](https://aws.amazon.com/ec2/pricing/on-demand/), [Elastic Load Balancing](https://aws.amazon.com/elasticloadbalancing/pricing/), [VPC](https://aws.amazon.com/vpc/pricing/), and [EBS](https://aws.amazon.com/ebs/pricing/).

Read the focused guides before presenting or operating the lab:

- [Architecture and real/simulated boundaries](docs/architecture.md)
- [How and why this lab differs from the product example](docs/reference-comparison.md)
- [Short presentation script](docs/demo-script.md)
- [Operations runbook](docs/runbook.md)
- [Contribution guide and clean-room rules](CONTRIBUTING.md)
- [Third-party licenses and notices](THIRD_PARTY_NOTICES.md)
- [Repository settings review](docs/repository-settings.md)

## AWS CloudShell quick start

Open the public AWS CloudShell in `us-east-1` (N. Virginia), then run:

```bash
git clone https://github.com/jakedgy/teamwork-cloud.git
cd teamwork-cloud
make bootstrap-cloudshell
make preflight
make deploy
```

The bootstrap reuses compatible tools or installs checksum-pinned Helm and eksctl binaries under `$HOME/.local/bin`. It does not use `sudo`, edit your shell profile, call AWS APIs, or create resources. Public CloudShell `$HOME` storage persists separately in each region; VPC CloudShell storage does not persist. `make preflight` still checks prerequisites and AWS identity before `make deploy` creates billable resources.

## Prerequisites

You need an AWS account in which you may create EKS, IAM, EC2/VPC, Elastic Load Balancing, CloudFormation, and EBS resources, plus working local authentication (`aws sts get-caller-identity`). Install:

- AWS CLI v2
- `eksctl` with EKS Auto Mode support
- `kubectl`
- Helm 3
- `jq`
- OpenSSL
- GNU Make and Bash
- Docker only for `make container-test` or a local image build

The default region is `us-east-1`; set `AWS_REGION` to choose another. The default cluster name is `twc-lab`; set `CLUSTER_NAME` to override it. Preflight performs non-destructive checks and refuses account, region, cluster, or local-state mismatches.

## Managed-VPC quick start

The default mode creates a dedicated VPC with two public subnets in different Availability Zones, then creates the EKS Auto Mode cluster and installs the lab.

```bash
make preflight
make deploy
make status
```

Deployment takes longer than five minutes even though this is the five-minute getting-started path. `make deploy` waits for the workloads and NLB, then prints URLs for `/webapp`, `/admin`, and `/admin/license`.

The managed VPC intentionally has no NAT gateway. Its subnets assign public IPv4 addresses so Auto Mode nodes can reach public registries and AWS endpoints, while security groups still control inbound traffic. Each public subnet has the `kubernetes.io/role/elb=1` tag so EKS Auto Mode may place the internet-facing NLB there. This inexpensive prototype trade-off is unsuitable for production.

## Use an existing VPC

Existing mode never creates, routes, tags, modifies, or deletes your VPC. Supply one VPC and at least two public subnets in different Availability Zones:

```bash
NETWORK_MODE=existing VPC_ID=vpc-0123456789abcdef0 PUBLIC_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0fedcba9876543210 AWS_REGION=us-east-1 make deploy
```

Before cluster creation, the workflow verifies that every subnet belongs to the VPC, assigns public IPv4 addresses, has enough free addresses, routes through an internet gateway, spans at least two Availability Zones, and has the exact `kubernetes.io/role/elb=1` tag. Add or correct that tag yourself before retrying; the lab will not alter existing networking. See [the runbook](docs/runbook.md#existing-vpc-mode) for a separate preflight command and ownership details.

## Browser tour

Use the NLB hostname printed by `make status`:

1. Open `/webapp` and find the persistent **Simulated product layer** label.
2. Continue through `/authentication`; no credentials are accepted or required.
3. Open `/admin` to see the browser → NLB → ingress → simulator flow and the three live dependency cards.
4. Open `/admin/license`. **Not activated** is the expected state because no Teamwork Cloud binaries, FlexNet server, or DSLS server exists.
5. Optionally inspect the read-only JSON at `/api/health`.

All three dependency cards should become green after startup. Startup transitions may briefly appear red while Cassandra, ZooKeeper, and Artemis initialize.

## Demonstrate failure and recovery

Scale one lab-owned dependency to zero:

```bash
make demo-failure SERVICE=artemis
```

Confirm the prompt. Within roughly 20 seconds, the Artemis card on `/admin` should turn red while the simulator and other cards remain available. Restore the recorded service with:

```bash
make demo-restore
```

The restore command returns the recorded workload to one replica and waits for readiness. The card should return to green after the next health refresh. Only `cassandra`, `zookeeper`, and `artemis` are accepted failure targets; see the [demo script](docs/demo-script.md) for a presentation-ready sequence.

## Architecture at a glance

```text
Browser --HTTP--> AWS NLB --> ingress-nginx --> simulator Service
                                                   |--CQL----> Cassandra
                                                   |--ruok---> ZooKeeper
                                                   `--STOMP--> Artemis
```

Persistent EBS claims back the three dependency StatefulSets. The simulator has no Kubernetes RBAC permissions, AWS credentials, mutation endpoints, or proprietary behavior. The complete component mapping and lifecycle are in [docs/architecture.md](docs/architecture.md).

## Troubleshooting

Start with:

```bash
make status
```

Common causes are an NLB still provisioning, an untagged public subnet, a pending EBS claim, an unscheduled Pod, or a dependency still starting. Use only the repository-owned kubeconfig for direct inspection:

```bash
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab get pods,pvc,service,ingress
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab get events --sort-by=.lastTimestamp
```

Do not delete Pods, claims, load balancers, stacks, or VPC resources by hand. Preserve a failed deployment for inspection, then use the scoped recovery and teardown commands in [docs/runbook.md](docs/runbook.md).

## Destroy the lab

```bash
make destroy
```

Review the exact account, region, cluster, and network ownership shown at the confirmation prompt. Teardown removes the Helm releases, waits for the NLB to disappear, removes the recorded cluster, checks tagged residuals, and deletes the VPC stack only in managed mode. Existing VPC resources are never deleted. If cleanup is incomplete, local state is preserved so you can diagnose and safely retry `make destroy`.

## Mapping the original reference

The [original Teamwork Cloud Kubernetes deployment example](https://docs.nomagic.com/spaces/TWCloud2024xR1/pages/178163939/Deployment%2Bexample%2Bfor%2BTeamwork%2BCloud%2Bwith%2Bservices%2Bon%2BKubernetes) targets a larger, self-managed environment with Teamwork Cloud and Web Application Platform binaries, multiple replicas, local persistent volumes, MetalLB, KEDA, and additional product services. This lab maps it as follows:

| Reference component | This lab |
| --- | --- |
| Teamwork Cloud and Web Application Platform | Explicit read-only Go simulator; no proprietary protocols or binaries |
| Cassandra, ZooKeeper, Artemis | Real, single-replica services with native protocol checks |
| ingress-nginx | Real ingress controller |
| MetalLB | Replaced by EKS Auto Mode's AWS NLB integration |
| Local persistent volumes | EBS-backed persistent volume claims |
| Multiple replicas and scaling | Collapsed to one replica for a cost-conscious failure demo |
| KEDA and optional product services | Omitted |

This is a clean-room educational reduction. It must not be used to infer Teamwork Cloud compatibility, behavior, security, or production sizing.

## CI and image publication

Pull requests and `main` run only free, local verification: Go tests and vet, Helm rendering, offline lifecycle tests, shell checks, a non-root container assertion, and Trivy. They receive no AWS credentials. Version tags and manually supplied versions publish `linux/amd64` and `linux/arm64` images to GHCR with a version tag and a `sha-<commit>` tag; the workflows never publish `latest` and refuse to overwrite an existing version tag.

Dependency updates are configured in [`renovate.json`](renovate.json) for the hosted [Mend Renovate GitHub App](https://github.com/apps/renovate). Renovate runs in a weekly Monday window, groups non-major infrastructure updates, keeps Go changes separate for license review, limits open PRs, and never automerges. The checksum-coupled Helm and eksctl versions in `scripts/bootstrap-cloudshell.sh` remain manual so a version cannot change without its verified archive checksum.

The **EKS smoke test** workflow is manual because it creates paid resources. Configure the `eks-smoke` GitHub environment with required reviewers and restrict its deployment branches to the repository default branch. Configure `AWS_ROLE_ARN` and `AWS_REGION` as environment or repository **variables** (neither value is a secret). The role must have the scoped permissions required by `make preflight`, `make deploy`, and `make destroy`. Do not configure long-lived AWS access-key secrets.

Create the repository before writing the role's OIDC trust policy, then obtain its actual owner and repository IDs. Repositories created after July 15, 2026 use an immutable environment subject shaped like `repo:jakedgy@OWNER_ID/teamwork-cloud@REPO_ID:environment:eks-smoke`; substitute the real numeric IDs and require that exact value in the AWS trust condition. Older repositories may use the legacy name-only subject. Confirm the format against GitHub's [OIDC subject reference](https://docs.github.com/en/actions/reference/security/oidc) rather than copying a placeholder into AWS.

The workflow publishes the current commit as a unique `smoke-<run-id>-<short-sha>` image before deployment. The `ghcr.io/jakedgy/teamwork-cloud` package must be public so EKS can pull it anonymously; the chart intentionally configures no registry credential. Each run uses `twc-lab-smoke-${{ github.run_id }}` and refreshes its OIDC credentials immediately before the always-run `CONFIRM=1 make destroy` step.

## License and contributions

Original work in this repository is available under the [Zero-Clause BSD license](LICENSE). Third-party dependencies, images, charts, and tools remain under their own terms; see [third-party notices](THIRD_PARTY_NOTICES.md). Contributions are welcome under the focused [contribution guide](CONTRIBUTING.md).

The GitHub posture observed on 2026-07-22 and owner-controlled hardening recommendations are recorded in [repository settings](docs/repository-settings.md). Repository automation does not silently change those settings.
