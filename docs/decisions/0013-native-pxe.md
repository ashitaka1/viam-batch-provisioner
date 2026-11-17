# 13. Answer PXE natively in the v2 server

Status: Accepted

Date: 2026-10-02

Amended by: [30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)

Amended by: [50. Server mode is one unprivileged daemon that answers PXE itself](0050-one-server-daemon.md)

## Context

Today dnsmasq answers PXE while the watcher sniffs the wire to learn which MACs arrived. These are two programs that reconstruct one event, plus an external dependency. Proxy DHCP (RFC 4578 PXE options) and TFTP (RFC 1350) are small, well-specified protocols.

Decision 30 amends this record: it makes the server daemon the helper's XPC peer. Decision 50 amends it too: it moves PXE into the unprivileged server and drops the helper.

## Decision

The v2 server answers proxy DHCP and serves TFTP itself on SwiftNIO, in a small privileged helper registered with `SMAppService` that owns only the UDP sockets and talks to the app over XPC.

## Consequences

- The server sees each PXE client because it answers it, so the watcher and dnsmasq go away. This supersedes [1. Run dnsmasq natively](0001-run-dnsmasq-natively.md) once built.
- The privileged surface is limited to the helper.
- The project owns a DHCP and TFTP implementation.

## Alternatives

None recorded.
