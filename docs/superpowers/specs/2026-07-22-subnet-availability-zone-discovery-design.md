# Subnet Availability Zone Discovery Fix

## Problem

The deployment renderer and existing-network preflight query AWS CLI with
`Subnets[].join(...)`. With text output, AWS CLI renders that list of scalar
strings on one tab-separated line. The scripts expect one subnet per line, so
valid selections containing two or more subnets are miscounted or misparsed.
The fake AWS CLI currently hides the mismatch by emitting one row per line.

The renderer writes eksctl's public subnet configuration as a map keyed by
Availability Zone. Multiple selected subnets in the same Availability Zone
would therefore create duplicate YAML keys.

## Design

Both subnet queries will use a JMESPath multiselect list so AWS CLI text output
contains one record per line:

- The renderer will request `[AvailabilityZone, SubnetId]`.
- Existing-network preflight will request the same validation fields it uses
  today, but as a multiselect list instead of joined scalar strings.

The renderer will validate the discovered records before writing cluster
configuration. It will require:

- every requested subnet to be returned exactly once;
- at least two returned subnets;
- at least two Availability Zones; and
- exactly one selected subnet per Availability Zone.

Duplicate Availability Zones will produce a clear error instead of ambiguous
eksctl YAML. Three or more subnets remain supported when each belongs to a
distinct Availability Zone.

Existing-network preflight will apply the same unique-Availability-Zone rule so
invalid selections fail during preflight rather than during rendering. Managed
mode will receive the renderer validation as defense against malformed or
unexpected CloudFormation outputs.

## Diagnostics

The expected initial CloudFormation "stack does not exist" probe in deployment
will disable the inherited `ERR` trap inside its command substitution, matching
the existing preflight probes. This removes the misleading line-67 failure
diagnostic without changing stack-creation behavior.

## Testing

Operational tests will model actual AWS CLI text formatting and cover:

- a managed deployment with two subnets;
- an existing-network deployment with three subnets in distinct Availability
  Zones;
- rejection of multiple selected subnets in one Availability Zone;
- renderer rejection when AWS omits or duplicates a requested subnet; and
- absence of a false command-failure diagnostic during the expected initial
  stack lookup.

The full `make verify` suite will remain the completion gate.
