# Operations runbook

This runbook operates only the resources recorded for this lab. It never requires broad deletion commands. Keep `.twc-lab/` private: it contains the lab-owned kubeconfig, state, rendered cluster configuration, and generated demo credentials. Never print or share `.twc-lab/secrets.yaml`.

## Preflight

For the default managed network:

```bash
AWS_REGION=us-east-2 CLUSTER_NAME=twc-lab make preflight
```

A successful preflight identifies the authenticated AWS account, selected region and cluster, required tools, and an available or matching managed VPC stack. It performs non-destructive AWS checks and does not create the cluster.

Stop on any identity or state mismatch. Confirm the active identity independently with `aws sts get-caller-identity`; do not edit `.twc-lab/state.env` to bypass the guard. A same-named cluster without matching local ownership state is intentionally not adopted.

Typical actionable failures:

- **Missing command:** install the named CLI, then rerun preflight.
- **AWS authentication:** renew the intended profile or SSO session; verify the account before retrying.
- **Permission denied:** have the account administrator grant the specific reported read or lifecycle permission.
- **Region or cluster mismatch:** use the values associated with the recorded deployment, or finish its scoped teardown before starting another.
- **Existing network validation:** correct the exact subnet property in your AWS account; the lab never changes existing network resources.

## Managed network mode

Managed mode is the default. It creates a dedicated VPC with two public subnets and records ownership before creating the EKS Auto Mode cluster:

```bash
AWS_REGION=us-east-2 CLUSTER_NAME=twc-lab make deploy
make status
```

The subnets assign public node IPv4 addresses and route through an internet gateway. They carry `kubernetes.io/role/elb=1`, which tells EKS Auto Mode where it may provision the public NLB. There is no NAT gateway. Treat this as an inexpensive public prototype, not a production network.

## Existing VPC mode

Choose at least two public subnets in different Availability Zones. Each must belong to the supplied VPC, map public IPv4 addresses on launch, have sufficient available IPs, route to an internet gateway, and carry the exact `kubernetes.io/role/elb=1` tag.

Run preflight with the same values you will deploy:

```bash
NETWORK_MODE=existing VPC_ID=vpc-0123456789abcdef0 PUBLIC_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0fedcba9876543210 AWS_REGION=us-east-2 make preflight
```

Then deploy:

```bash
NETWORK_MODE=existing VPC_ID=vpc-0123456789abcdef0 PUBLIC_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0fedcba9876543210 AWS_REGION=us-east-2 make deploy
```

The deployment records the exact VPC and subnet IDs as externally owned. `make destroy` removes the lab but never deletes or modifies those VPC resources, routes, gateways, or tags.

## Status and endpoint checks

Start every investigation with:

```bash
make status
```

It reports the recorded account, region, cluster, network mode and ownership, Helm releases, Pods, claims, NLB hostname, and simulator health. For automation, `JSON=1 make status` emits one JSON object.

Check the public API without sending credentials:

```bash
curl --fail --show-error --silent http://<exact-NLB-hostname>/api/health
```

The endpoint is HTTP-only and public. Its output should contain exactly the three dependency results; errors are intentionally scrubbed.

## Kubernetes diagnostics

Always use the lab-owned kubeconfig explicitly so commands cannot target another cluster:

```bash
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab get pods,pvc,service,ingress -o wide
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab get events --sort-by=.lastTimestamp
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab describe deployment twc-lab-simulator
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab logs deployment/twc-lab-simulator --tail=100
```

Use `describe` on one exact lab resource reported by `get`; do not use commands that delete, replace, or force resources. Never print the Artemis Secret or the local secrets file.

## NLB is pending or unreachable

Inspect the ingress controller Service and recent events:

```bash
kubectl --kubeconfig .twc-lab/kubeconfig -n ingress-nginx get service ingress-nginx-controller -o wide
kubectl --kubeconfig .twc-lab/kubeconfig -n ingress-nginx describe service ingress-nginx-controller
kubectl --kubeconfig .twc-lab/kubeconfig -n ingress-nginx get events --sort-by=.lastTimestamp
```

Confirm that the Service shows class `eks.amazonaws.com/nlb`, an internet-facing scheme, and eventually a hostname. If subnet discovery fails, verify both selected subnets are public and have `kubernetes.io/role/elb=1`. In existing mode, correct the network yourself and rerun `make deploy`; the repository will not retag it. If DNS exists but HTTP fails, inspect ingress-nginx Pods and the `twc-lab-simulator` endpoints before changing AWS resources.

## PVC is Pending

Inspect only the lab claims and StorageClass:

```bash
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab get pvc
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab describe pvc <exact-pvc-name>
kubectl --kubeconfig .twc-lab/kubeconfig get storageclass auto-ebs -o yaml
```

Events commonly identify provisioning, topology, quota, or IAM problems. Correct the reported account or cluster configuration and rerun `make deploy`. Do not delete a claim to clear an error: it contains the dependency's lab data and lifecycle metadata.

## Pod is Pending, restarting, or not ready

Use the exact Pod name from the first command:

```bash
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab get pods -o wide
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab describe pod <exact-pod-name>
kubectl --kubeconfig .twc-lab/kubeconfig -n twc-lab logs <exact-pod-name> --tail=100
```

For `Pending`, read scheduling events for capacity, resource, and volume constraints. For restarts, read current logs; add `--previous` only for that exact Pod and container if Kubernetes reports a prior instance. Cassandra can take several minutes to initialize on first boot. A red dependency card with a healthy simulator means the dependency check—not the web process—is failing.

## Safe failure recovery

Use the lifecycle command rather than changing replicas directly:

```bash
make demo-restore
make status
```

The restore script validates account and cluster state, restores only the recorded allowlisted service to one replica, and waits. It is safe when no failure is active. If it reports a state mismatch, stop and validate AWS identity rather than editing state or scaling another workload.

For a partially failed deployment, preserve resources for inspection. Once the root cause is corrected, rerun `make deploy`; the workflow is designed to reconcile a matching lab-owned deployment. Do not manually remove CloudFormation, NLB, EBS, or EKS resources underneath recorded state.

## Teardown and residual checks

Run:

```bash
make destroy
```

Before confirming, compare the displayed account, region, cluster, and network mode to your intended target. Teardown removes application and ingress releases, waits for the NLB to disappear, deletes the recorded cluster, checks tagged load balancer and EBS residuals, and finally deletes the VPC stack only in managed mode.

If teardown reports an incomplete phase, keep `.twc-lab/state.env`, resolve the exact reported blocker, and rerun `make destroy`. Do not delete the state file until the command confirms cleanup.

For an additional read-only residual check, replace the placeholders with the exact cluster and region printed by status or teardown:

```bash
aws eks describe-cluster --name <exact-cluster-name> --region <exact-region>
aws resourcegroupstaggingapi get-resources --region <exact-region> --tag-filters Key=kubernetes.io/cluster/<exact-cluster-name>
```

After a successful destroy, `describe-cluster` should report that the exact cluster is not found and the tag query should return no lab-owned resources. In managed mode, also check the exact recorded CloudFormation stack name with `aws cloudformation describe-stacks --stack-name <exact-stack-name> --region <exact-region>`; it should be absent. In existing mode, the VPC and subnets should remain unchanged.
