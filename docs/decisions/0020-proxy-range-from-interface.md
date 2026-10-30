# 20. Derive the proxy-DHCP range from the serving interface

Date: 2026-10-03

## Status

Accepted

## Context

`dnsmasq.conf` hardcoded the office subnet, so serving from any other network meant editing it.

## Decision

`dnsmasq.conf` carries no `dhcp-range`. `scripts/pxe-subnet.sh` computes `<network>,proxy,<netmask>` from the serving interface at `just serve` or daemon install. `PXE_PROXY_SUBNET` (CIDR) in `site.env` overrides it.

## Consequences

The host serves whatever network it's on. A provisioning network that differs from the interface's own subnet needs the override.
