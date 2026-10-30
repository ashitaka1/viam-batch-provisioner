# 28. Bind DHCP sockets to the interface, not its address

Date: 2026-10-30

## Status

Accepted

## Context

PXE firmware broadcasts its discover to 255.255.255.255:67. On macOS a UDP socket bound to a unicast address never receives broadcast datagrams, so `ProvisionerPXE` cannot bind the serving interface's IP for DHCP. Binding 0.0.0.0 receives the broadcast but from every interface.

## Decision

The DHCP and PXE sockets bind 0.0.0.0 and set `IP_BOUND_IF` to the serving interface's index. The TFTP socket binds the interface address, since its clients address it directly.

## Consequences

The server answers only discovers arriving on the configured interface. `SO_REUSEADDR` and `SO_BROADCAST` are set on the DHCP sockets. Offers go to 255.255.255.255:68 unless a configuration supplies another destination.
