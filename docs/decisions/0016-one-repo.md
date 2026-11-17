# 16. Keep v2 and the current tooling in one repo

Status: Accepted

Date: 2026-10-02

## Context

The Swift package and the bash/Python tooling share netboot configs, autoinstall templates and GRUB assets. A separate repo would duplicate them or need a submodule.

## Decision

The Swift package lives in this repo beside the existing tooling, which keeps working until the Swift server replaces it.

## Consequences

- There is one copy of the shared assets.
- The existing tooling remains available for debugging and one-off operations after the Swift server ships.

## Alternatives

- Put the Swift package in a separate repo. A separate repo would duplicate the shared assets or need a submodule.
