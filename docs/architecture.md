# Architecture and boundaries

This lab preserves the instructional topology of the Teamwork Cloud 2024x Refresh1 Kubernetes deployment example without redistributing or emulating Teamwork Cloud. It is a clean-room EKS Auto Mode demonstration, not a supported product deployment or production design.

## Request and health flow

```text
Public internet
    |
    | HTTP
    v
AWS Network Load Balancer
    |
    v
ingress-nginx controller
    |
    v
twc-lab-simulator ClusterIP Service
    |
    v
Go simulator Pod
    |-- CQL query on 9042 ----------------> Cassandra StatefulSet + EBS PVC
    |-- ruok/imok on 2181 ----------------> ZooKeeper StatefulSet + EBS PVC
    `-- authenticated STOMP on 61616 -----> Artemis StatefulSet + EBS PVC
```

The ingress has no hostname restriction, so the AWS-generated NLB hostname works directly. The external endpoint is intentionally HTTP-only. The NLB targets ingress-nginx Pods by IP; ingress-nginx routes `/`, `/webapp`, `/authentication`, `/admin`, and `/api/health` to the simulator Service.

The browser never talks directly to Cassandra, ZooKeeper, Artemis, Kubernetes, or AWS. It reads the simulator pages and polls `/api/health` every ten seconds. The simulator checks each dependency with a bounded timeout and publishes only a short, scrubbed result.

## What is real

- EKS Auto Mode supplies the Kubernetes control plane integration, managed compute, networking, and EBS provisioning.
- ingress-nginx receives traffic from an internet-facing AWS NLB.
- Cassandra accepts a CQL session and a harmless query against `system.local` on port 9042.
- ZooKeeper receives `ruok` and must reply `imok` on port 2181.
- Artemis accepts an authenticated STOMP connection on port 61616; no message is sent.
- The three dependencies are StatefulSets with EBS-backed persistent volume claims.
- The Go HTTP process, its dependency checks, and the visible health transitions are real.

These checks establish reachability and a small protocol handshake. They do not establish Teamwork Cloud compatibility, data-model correctness, performance, high availability, or production readiness.

## What is simulated

Everything presented as a product experience is explicitly simulated:

- `/webapp` is an educational landing page, not Web Application Platform.
- `/authentication` does not authenticate users or accept credentials.
- `/admin` is a read-only lab dashboard, not Teamwork Cloud administration.
- `/admin/license` always explains that the product is **Not activated**; no FlexNet or DSLS integration exists.
- There are no Teamwork Cloud servers, proprietary protocols, collaboration functions, client connections, product repositories, or vendor binaries.

The simulator has no Kubernetes mutation permissions, additional RBAC bindings, or AWS credentials. The only generated credential is the demo-only Artemis secret, which is kept in a gitignored local values file and a Kubernetes Secret. Browser responses never contain it.

## Network model

Both modes place Auto Mode capacity in public subnets. Public IPv4 assignment lets nodes reach registries and AWS APIs without a NAT gateway; this is a cost-conscious lab choice, not a production recommendation. Security groups still limit inbound access.

The managed mode creates a dedicated VPC, internet gateway, route table, and two public subnets in separate Availability Zones. The existing mode validates caller-supplied resources and never modifies them. In either mode, each subnet must carry:

```text
kubernetes.io/role/elb=1
```

EKS Auto Mode uses that tag to discover public subnets for the internet-facing NLB.

## Storage and failure lifecycle

Cassandra requests 8 GiB; ZooKeeper and Artemis request 2 GiB each. The chart's `auto-ebs` StorageClass supplies EBS-backed claims unless deployment values select an existing StorageClass. This lab uses one replica per dependency, so a single failure is intentionally visible and there is no failover.

`make demo-failure SERVICE=<name>` scales only the allowlisted StatefulSet (`cassandra`, `zookeeper`, or `artemis`) from one replica to zero. It records the target in `.twc-lab/state.env`; it does not delete the StatefulSet or its claim. The simulator remains up, its protocol check fails, and the dashboard changes after its next refresh.

`make demo-restore` reads the recorded target, scales that StatefulSet back to one, waits for readiness, and leaves its persistent volume intact. `make destroy` is different: it removes the application and ingress releases, waits for the NLB to disappear, deletes the recorded cluster, checks cluster-tagged residuals, and deletes the VPC stack only when state proves that the repository created it.

## Original-to-lab mapping

| 2024x Refresh1 reference | Lab implementation | Boundary or trade-off |
| --- | --- | --- |
| Teamwork Cloud services | Go simulator | Product binaries, protocols, storage, and behavior are absent |
| Web Application Platform applications | Simulator routes | Familiar route shape only; no copied UI or functionality |
| Authentication and license management | Explanatory read-only pages | No credential input, identity system, FlexNet, or DSLS |
| Cassandra | Real Cassandra, one replica | Native CQL health check; not a Teamwork Cloud repository |
| ZooKeeper | Real ZooKeeper, one replica | Native `ruok` health check |
| ActiveMQ Artemis | Real Artemis, one replica | Authenticated STOMP handshake; no application messages |
| ingress-nginx | Real ingress-nginx | Same routing role |
| MetalLB | EKS Auto Mode NLB | AWS-managed external load balancer integration |
| Local persistent volumes | EBS persistent volume claims | Cloud storage, prototype sizes |
| Multiple replicas | One replica per workload | Lower cost, no high availability |
| KEDA and optional product services | Omitted | Outside the lab's demonstration goal |

See the [operations runbook](runbook.md) for diagnosis and the [presentation script](demo-script.md) for a concise walkthrough.
