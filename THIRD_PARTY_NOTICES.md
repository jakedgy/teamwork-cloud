# Third-party notices

Original work in this repository is licensed under the [Zero-Clause BSD](LICENSE). That license does not replace or modify the terms that apply to third-party software.

## Code compiled into the simulator

These modules are declared by `go.mod` and provide packages reachable from `./cmd/twc-lab`. `make verify` fails if the resolved compiled dependency inventory or the copied license artifacts change, so updates must be reviewed deliberately.

| Component | License and notices |
| --- | --- |
| `github.com/gocql/gocql v1.7.0` | Apache-2.0 ([LICENSE](LICENSES/gocql-LICENSE.txt), [NOTICE](LICENSES/gocql-NOTICE.txt)) |
| `github.com/golang/snappy v0.0.3` | BSD-3-Clause ([LICENSE](LICENSES/golang-snappy-LICENSE.txt)) |
| `github.com/hailocab/go-hostpool v0.0.0-20160125115350-e80d13ce29ed` | MIT ([LICENSE](LICENSES/go-hostpool-LICENSE.txt)) |
| `gopkg.in/inf.v0 v0.9.1` | BSD-3-Clause ([LICENSE](LICENSES/inf-LICENSE.txt)) |

## Separately distributed components

This repository does not relicense the separately distributed components below. The license terms and notices shipped with each acquired artifact are authoritative.

| Component | Upstream | Terms |
| --- | --- | --- |
| `cassandra:4.1.4` | [Apache Cassandra](https://github.com/apache/cassandra) | Apache-2.0 plus image notices |
| `zookeeper:3.9.2` | [Apache ZooKeeper](https://github.com/apache/zookeeper) | Apache-2.0 plus image notices |
| `apache/activemq-artemis:2.32.0` | [Apache ActiveMQ Artemis](https://github.com/apache/activemq-artemis) | Apache-2.0 plus image notices |
| `ingress-nginx chart 4.13.3` | [ingress-nginx](https://github.com/kubernetes/ingress-nginx) | Apache-2.0 plus chart/image dependencies |
| `gcr.io/distroless/static-debian12` pinned by digest | [Distroless](https://github.com/GoogleContainerTools/distroless) | Apache-2.0 project code plus included Debian-material licenses |
| `golang:1.26.5-alpine` pinned by digest, build stage only | [Docker Official Image for Go](https://github.com/docker-library/golang) | Upstream Go/Alpine/image terms; not the final runtime base |

AWS CLI, eksctl, Kubernetes, Helm, Docker, Make, Bash, OpenSSL, jq, and GitHub Actions are acquired separately under their own terms.

## Proprietary software boundary

This repository contains no Teamwork Cloud or Web App Platform binary, WAR, chart, license material, copied UI asset, or non-public documentation. Those names only describe the inspiration for this independent simulator. No compatibility, endorsement, activation, or trademark license is claimed.
