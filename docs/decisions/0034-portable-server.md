# 34. Keep the server portable to Linux

Date: 2026-10-31

## Status

Accepted

## Context

Server mode is two headless daemons with clients for status (decision 30). SwiftNIO, Hummingbird and the OpenAPI runtime run on Linux. The macOS-specific parts are `SMAppService` registration, `IP_BOUND_IF` on the DHCP sockets (decision 28) and Bonjour advertisement.

## Decision

v2 ships a macOS server only, and `ProvisionerServer` and `ProvisionerPXE` stay buildable on Linux. Interface binding and service advertisement sit behind small platform shims (`SO_BINDTODEVICE` and Avahi on Linux), and a Linux build of both targets is checked in a container.

## Consequences

A headless Linux server under systemd is packaging work when it's wanted. Server code imports Foundation and the shims, not Darwin directly. Building the Linux server in v2, or allowing Darwin-only server code, were the alternatives.
