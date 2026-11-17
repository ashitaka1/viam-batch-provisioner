# 34. Keep the server portable to Linux

Status: Accepted

Date: 2026-10-31

## Context

Server mode is two headless daemons with clients for status ([30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)). SwiftNIO, Hummingbird and the OpenAPI runtime run on Linux. The macOS-specific parts are `SMAppService` registration, `IP_BOUND_IF` on the DHCP sockets ([28. Bind DHCP sockets to the interface, not its address](0028-bind-dhcp-to-interface.md)) and Bonjour advertisement.

## Decision

v2 ships a macOS server only, and `ProvisionerServer` and `ProvisionerPXE` stay buildable on Linux. Interface binding and service advertisement sit behind small platform shims (`SO_BINDTODEVICE` and Avahi on Linux), and a Linux build of both targets is checked in a container.

## Consequences

- A headless Linux server under systemd is packaging work when it is wanted.
- Server code imports Foundation and the shims, not Darwin directly.

## Alternatives

The record states no reason that these options were not chosen.

- Building the Linux server in v2.
- Allowing Darwin-only server code.
