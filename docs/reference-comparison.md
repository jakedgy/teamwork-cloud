# How this lab differs from the product example

The [Teamwork Cloud 2024x Refresh1 Kubernetes deployment example](https://docs.nomagic.com/spaces/TWCloud2024xR1/pages/178163939/Deployment%2Bexample%2Bfor%2BTeamwork%2BCloud%2Bwith%2Bservices%2Bon%2BKubernetes) describes a test deployment on a largely self-managed Kubernetes environment. This lab keeps its most useful traffic and dependency relationships, but moves them to EKS Auto Mode and replaces the unavailable product layer.

This is an architectural analogy, not a port of the vendor charts. The question behind each change was: **does this component teach something necessary about running this topology on EKS?**

## The short version

| Concern | Product example | This lab | Why it differs |
| --- | --- | --- | --- |
| Kubernetes platform | Control-plane VM, three worker VMs, containerd, and Calico | EKS Auto Mode | AWS owns the control plane, node lifecycle, pod networking, load-balancer controller, and block-storage controller |
| Product workloads | Teamwork Cloud plus Web Application Platform applications | One explicitly labeled Go simulator | Product binaries and a license server are unavailable and must not be imitated |
| External load balancer | MetalLB allocates and advertises a reserved IP | EKS Auto Mode provisions an AWS Network Load Balancer | MetalLB solves the bare-metal `LoadBalancer` problem; EKS already has a cloud-provider implementation |
| HTTP routing | ingress-nginx with sticky sessions | ingress-nginx with cookie affinity | This routing layer is still relevant, observable, and close to the reference topology |
| Event-driven scaling | KEDA, installed for the Simulation application | Omitted | The product Simulation workload and its event source do not exist here, so a scaler would have nothing honest to scale |
| Stateful dependencies | Cassandra, ZooKeeper, and Artemis supporting Teamwork Cloud | Real single-replica services with protocol health checks | Preserves dependency discovery, readiness, storage, and failure behavior at prototype cost |
| Persistent storage | Storage supplied through the reference charts and target cluster | Dynamically provisioned `gp3` EBS volumes | EBS is the native persistent block-storage path for this EKS environment |
| Image supply chain | Build product images and push them to a test registry on an admin host | Public simulator image in GHCR; upstream dependency images | Avoids redistributing product artifacts and removes a registry from the learning path |
| Public endpoint | Custom DNS, TLS material, and a reserved IP | AWS-generated NLB hostname over HTTP | Removes domain and certificate ownership from a short-lived lab; explicitly unsuitable for sensitive data |
| Availability and scale | Product-oriented topology and sizing | One replica for each lab workload | Keeps cost and failure behavior obvious; demonstrates no failover or production sizing |

## MetalLB became an AWS NLB

A Kubernetes `Service` with `type: LoadBalancer` is only a request. Something outside the core Kubernetes API must allocate an address and arrange for traffic to reach the Service.

The product example targets infrastructure where that capability is not supplied by a cloud provider. MetalLB fills the gap by selecting an address from an operator-provided pool and advertising it using layer 2 or BGP. That is why its setup needs both an `IPAddressPool` and an `L2Advertisement`.

This lab runs on AWS. EKS Auto Mode watches the same Kubernetes Service API and provisions an AWS Network Load Balancer in the tagged public subnets. Running MetalLB as well would duplicate ownership of the same concern and teach an AWS pattern that operators should not use. MetalLB's own documentation says AWS is not a supported target and recommends EKS instead.

What remains educational is the ownership boundary:

```text
Kubernetes Service type=LoadBalancer
        |
        +-- bare metal: MetalLB allocates and advertises an address
        |
        `-- this lab: EKS Auto Mode provisions and manages an AWS NLB
```

Further reading:

- [MetalLB concepts](https://metallb.io/concepts/)
- [MetalLB cloud compatibility](https://metallb.io/installation/clouds/)
- [EKS Auto Mode networking and load balancing](https://docs.aws.amazon.com/eks/latest/userguide/auto-networking.html)
- [Network Load Balancers on EKS](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)

## KEDA was removed, not replaced

KEDA connects an external event signal, such as queue depth, to Kubernetes autoscaling. It normally creates an HPA from a `ScaledObject` and changes a workload's replica count as the signal changes.

The reference installs KEDA for the product's Simulation web application. This lab has neither that application nor its event source. Installing KEDA without a real scaling signal would add operators and cluster-wide custom resource definitions while demonstrating only that a Helm chart can be installed.

EKS Auto Mode does scale **nodes** when Pods need capacity, but that is not a substitute for KEDA. These are different control loops:

```text
KEDA or HPA: workload demand -> change Pod count
EKS Auto Mode: unscheduled Pods -> change node capacity
```

The lab exercises only the second loop. If a future lesson adds a real queue-backed worker, KEDA would become meaningful.

Further reading:

- [KEDA overview](https://keda.sh/)
- [EKS Auto Mode features and responsibilities](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)

## We kept ingress-nginx

The NLB and ingress-nginx do different jobs. The NLB brings layer-4 traffic from AWS into the cluster. ingress-nginx then applies HTTP path rules and cookie affinity before forwarding requests to a ClusterIP Service.

Keeping ingress-nginx preserves an important part of the product example: several user-facing paths share one external endpoint, and sticky sessions are represented with the same controller family. The lab collapses those paths onto one simulator, but the browser-to-load-balancer-to-ingress-to-Service flow is real.

The lab uses the generated NLB hostname and has no host restriction. It also deliberately stops at HTTP. A serious deployment would add controlled DNS, TLS, certificate rotation, restricted network exposure, and an explicit ingress lifecycle.

Further reading:

- [Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [ingress-nginx session-affinity annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#session-affinity)

## EKS Auto Mode replaced node, CNI, and CSI operations

The reference asks operators to prepare control-plane and worker VMs, run containerd, install Calico, move kubeconfig files, and manage node access. Those are valid concerns for a self-managed cluster.

EKS Auto Mode changes that responsibility boundary. AWS manages the Kubernetes control plane and the Auto Mode node lifecycle, plus core networking, compute scaling, load-balancing, and block-storage capabilities. Operators still own the VPC design, IAM access, Kubernetes objects, application containers, data protection, and observability.

For persistent data, this lab defines a `StorageClass` with the Auto Mode provisioner `ebs.csi.eks.amazonaws.com`. The three StatefulSets request persistent volume claims; EKS provisions EBS volumes when their Pods are scheduled. One volume does not make a database highly available—it only lets its single Pod be replaced without intentionally discarding its claim.

Further reading:

- [How EKS Auto Mode manages cluster infrastructure](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)
- [EKS Auto Mode managed instances](https://docs.aws.amazon.com/eks/latest/userguide/automode-learn-instances.html)
- [Create an EKS Auto Mode storage class](https://docs.aws.amazon.com/eks/latest/userguide/create-storage-class.html)
- [Amazon EBS CSI storage on EKS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)

## The product layer is a hard boundary

The product example builds images from licensed Teamwork Cloud and Web Application Platform files, then deploys authentication, administration, collaboration, reporting, simulation, OSLC, resource, and export services.

This repository includes none of those files or behaviors. One small Go service provides clearly labeled routes and reports whether Cassandra, ZooKeeper, and Artemis respond to native protocol checks. The license page always stops at **Not activated**. No credential entry, product data model, repository compatibility, collaboration behavior, or licensing protocol is claimed.

The real dependencies are useful because they let operators observe:

- StatefulSet and persistent-volume lifecycles
- Cluster DNS and Service discovery
- readiness and startup behavior
- Secrets passed to a workload
- a dependency failure without losing the ingress path
- ordered, ownership-aware cleanup of cloud resources

They do not prove that a real Teamwork Cloud deployment would work with these manifests.

## We optimized for a disposable lesson

The reference itself is a test example rather than production guidance. This lab narrows the goal further: one person should be able to create it, inspect it, break one dependency, restore it, and destroy it without first operating a registry, DNS zone, certificate authority, autoscaling extension, or bare-metal routing layer.

That choice deliberately removes lessons in:

- highly available Cassandra, ZooKeeper, and Artemis design
- product-specific sizing and configuration
- KEDA trigger design and workload autoscaling
- certificate, DNS, and secret rotation
- private-subnet egress and production network segmentation
- backup, restore, monitoring, upgrades, and disaster recovery

If this prototype becomes a real product deployment, do not grow it one checkbox at a time. Return to the current vendor compatibility matrix and deployment guidance, obtain the licensed artifacts, and design the production platform around its actual availability, security, data, and support requirements.
