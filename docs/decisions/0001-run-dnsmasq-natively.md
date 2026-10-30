# 1. Run dnsmasq natively

Date: 2026-03-27

## Status

Accepted

## Context

PXE needs a proxy DHCP responder and a TFTP server on the host. The HTTP server already runs in Docker. Docker Desktop for Mac runs containers in a VM and can't give a container host networking, so a containerized dnsmasq never sees the broadcast DHCP discovers on the LAN.

## Decision

dnsmasq runs on the host, installed from Homebrew, in proxy mode alongside the LAN's own DHCP server.

## Consequences

The host needs `brew install dnsmasq` and root to bind ports 67 and 69. Only nginx runs in Docker. `just serve` and the dnsmasq LaunchDaemon start and stop it by pid file.
