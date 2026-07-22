# Short demo script

This presentation takes about five minutes after the cluster is healthy. Say up front: **the web, authentication, admin, and license screens are simulated; Cassandra, ZooKeeper, Artemis, ingress, the NLB, and their protocol health checks are real.**

## Before the audience joins

Run `make status` and keep the printed base URL handy. Open `/webapp` in one tab and `/admin` in another. Confirm that all three service cards are green. Do not enter or show any sensitive data; the site is public and HTTP-only.

## 1. Introduce the lab

Open:

```text
http://<NLB-hostname>/webapp
```

Point out **Simulated product layer** and the split between the educational product surface and real infrastructure. Expected result: the page identifies Cassandra, ZooKeeper, and Artemis as real dependencies and the product layer as simulated.

## 2. Show the license boundary

Open `/admin/license`. Expected result: **Not activated** is prominent, with an explanation that Teamwork Cloud binaries and FlexNet or DSLS licensing are absent. There is no activation form or place to enter a license key.

## 3. Show live health

Open `/admin`. Point out the request path and the CQL, `ruok`, and STOMP checks. Expected result: Cassandra, ZooKeeper, and Artemis are all green, with recent attempt times and latency.

## 4. Fail Artemis

In the repository terminal, run:

```bash
make demo-failure SERVICE=artemis
```

Confirm the exact target when prompted. Expected result: the Artemis StatefulSet scales to zero without deleting its persistent claim. Within about 20 seconds, the Artemis card turns red; Cassandra and ZooKeeper stay green and the simulated admin page stays reachable.

Restate that this is a deliberately induced dependency outage shown through a simulated product dashboard. It does not demonstrate real Teamwork Cloud failure behavior.

## 5. Restore service

Run:

```bash
make demo-restore
```

Expected result: the recorded Artemis StatefulSet returns to one ready replica. After the next dashboard refresh, the Artemis card returns to green without reinstalling the lab or losing its claim.

## 6. Close and clean up

Summarize the mapping: AWS NLB replaces MetalLB, EBS replaces local volumes, dependencies are reduced to one replica, and the unavailable proprietary layer is simulated. Then run:

```bash
make destroy
```

Review the exact account, region, cluster, and ownership prompt before confirming. Expected result: the lab reports removal of the releases, NLB, cluster, and—only in managed mode—the dedicated VPC stack, plus any residual resources it could not confirm removed. Never leave the paid lab running after the presentation.
