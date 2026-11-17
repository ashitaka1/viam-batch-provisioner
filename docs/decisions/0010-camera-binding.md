# 10. Bind hardware to names with the camera

Status: Accepted

Date: 2026-10-02

Amended by: [32. Provision only machines bound to a slot](0032-provision-only-bound-machines.md)

## Context

The watcher assigns queued names in PXE arrival order. When two machines boot together, which physical machine gets which name is arbitrary, and the operator learns it only afterwards. Reading MAC addresses off chassis labels or BIOS screens by hand is slow and error-prone.

Decision 32 amends this record: binding also happens from a client without a camera, and binding is required for provisioning.

## Decision

Clients with a camera scan a barcode or label on the chassis, or read the MAC from a firmware screen with Vision text recognition, to pre-bind a machine to a queue slot. Serial numbers and asset tags are recorded with the machine.

## Consequences

- The physical-to-logical binding is human-verified, and an asset inventory comes with it.
- The server needs a binding API and a rule for an unbound MAC that arrives while bindings exist.

## Alternatives

None recorded.
