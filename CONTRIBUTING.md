# Contributing

Thanks for helping make this deployment lab easier to understand and safer to operate. This repository is an educational EKS prototype with a simulated product layer; it is not Teamwork Cloud software and does not claim product compatibility.

## Clean-room boundary

Contributions must use public information and original work. Do not submit proprietary vendor binaries, WARs, charts, license files or keys, copied UI assets, authenticated download contents, or excerpts from non-public documentation. Keep the application visibly labeled **Simulated product layer**, read-only, and free of fake activation or compatibility claims.

## Safety boundaries

- Ordinary pull requests must not create paid AWS resources. Keep routine validation local and offline.
- Existing VPCs are externally owned. The supplied VPC, subnets, route tables, internet gateway, and tags are immutable external targets: workflows must not modify, retag, reroute, or delete them. EKS may create cluster-owned ENIs, security groups, and load balancers in the supplied network.
- Lifecycle changes must preserve recorded resource identity, explicit confirmation, bounded waits, and residual-resource checks.
- Never commit credentials, `.twc-lab` state, vendor materials, or real customer or project data.

## Before opening a pull request

Run:

```bash
make verify
make container-test
```

`make verify` checks Go tests and vet, rendered Helm output, offline lifecycle behavior, shell syntax, repository policy, and other local safety assertions. `make container-test` requires Docker and validates the built image, including its non-root runtime behavior. If Docker is unavailable and the change cannot affect the container, explain why that check was not run.

Keep changes focused. Describe the real-versus-simulated boundary and any operational impact. Dependency changes must update the applicable notices and `LICENSES` artifacts and pass the container test.

## Licensing contributions

Unless explicitly stated otherwise, original contributions are provided under the repository's [Zero-Clause BSD license](LICENSE). Submit only work you have the right to contribute. Preserve third-party notices and disclose all applicable third-party terms.

## Pull request checklist

- [ ] The simulator remains visibly labeled **Simulated product layer** and makes no activation or compatibility claim.
- [ ] No proprietary, authenticated-download, credential, sensitive, or real project material is included.
- [ ] Network ownership and teardown safety boundaries are preserved.
- [ ] `make verify` passes.
- [ ] `make container-test` passes when the change can affect the image or its dependencies.
- [ ] Dependency and image changes include updated notices and license artifacts.

## Security reports

Open a GitHub Issue for security reports. Do not include credentials, secrets, personal data, or other sensitive material.
