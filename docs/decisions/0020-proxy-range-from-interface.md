# 20. Derive the proxy-DHCP range from the serving interface

Status: Accepted

Date: 2026-10-03

## Context

`dnsmasq.conf` hardcoded the office subnet, so serving from any other network meant editing it.

## Decision

`dnsmasq.conf` has no `dhcp-range`. `scripts/pxe-subnet.sh` computes `<network>,proxy,<netmask>` from the serving interface at `just serve` or at daemon install. `PXE_PROXY_SUBNET` (CIDR) in `site.env` overrides the computed value.

## Consequences

- The host serves whatever network it is on.
- A provisioning network that differs from the interface's own subnet needs the override.

## Alternatives

None recorded.
