# 13. Answer PXE natively in the v2 server

Date: 2026-10-02

## Status

Accepted; amended by decision 30, which makes the server daemon the helper's XPC peer

## Context

Today dnsmasq answers PXE while the watcher sniffs the wire to learn which MACs arrived: two programs reconstructing one event, plus an external dependency. Proxy DHCP (RFC 4578 PXE options) and TFTP (RFC 1350) are small, well-specified protocols.

## Decision

The v2 server answers proxy DHCP and serves TFTP itself on SwiftNIO, in a small privileged helper registered with `SMAppService` that owns only the UDP sockets and talks to the app over XPC.

## Consequences

The server sees each PXE client because it answers it, so the watcher and dnsmasq go away (superseding decision 1 once built). The privileged surface is limited to the helper. The project owns a DHCP and TFTP implementation.
