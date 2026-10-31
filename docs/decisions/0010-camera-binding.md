# 10. Bind hardware to names with the camera

Date: 2026-10-02

## Status

Accepted; amended by decision 32, under which binding also happens from a client without a camera and is required for provisioning

## Context

The watcher assigns queued names in PXE arrival order. When two machines boot together, which physical machine gets which name is arbitrary, and the operator learns it only afterwards. Reading MAC addresses off chassis labels or BIOS screens by hand is slow and error-prone.

## Decision

Clients with a camera scan a barcode or label on the chassis, or read the MAC from a firmware screen with Vision text recognition, to pre-bind a machine to a queue slot. Serial numbers and asset tags are recorded with the machine.

## Consequences

The physical-to-logical binding is human-verified, and an asset inventory comes with it. The server needs a binding API and a rule for an unbound MAC that arrives while bindings exist.
