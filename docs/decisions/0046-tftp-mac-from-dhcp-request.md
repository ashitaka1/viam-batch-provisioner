# 46. Tie a TFTP read to a MAC through the client's DHCP request

Date: 2026-11-05

Status: Accepted

## Context

Server-observed stages ([36. Detect early failures from server-observed stages](0036-server-observed-stages.md)) need "boot files sent" per machine. A TFTP request carries only the client's IP address. Proxy DHCP assigns no address, and the offer's `PXE_DISCOVERY_CONTROL` skips the port-4011 exchange, so the server never sees an IP tied to a MAC in its own replies. The firmware's DHCPREQUEST to the lab's DHCP server is broadcast to port 67, where the proxy listens, and names the address in option 50. This decision is unverified on hardware until the run for [ProvisionerHelper: privileged daemon via SMAppService (#43)](https://github.com/ashitaka1/viam-batch-provisioner/issues/43).

## Decision

ProvisionerPXE records the MAC and address of each PXE client's DHCPREQUEST (option 50, else `ciaddr`) in a `LeaseTable` of at most 4096 addresses. A `fileSent` event carries the MAC recorded for the reader's address, or none.

## Consequences

- The mapping is portable and comes from the wire the proxy already reads.
- A client whose request is unicast, or a DHCP server that acknowledges a different address than requested, yields `fileSent` without a MAC. The event still carries the address and filename.
- GRUB's config file names (`grub.cfg-01-<mac>`) identify the machine independently.

## Alternatives

- Reading the kernel's ARP table for the address needs a platform shim for Linux ([34. Keep the server portable to Linux](0034-portable-server.md)), and an entry exists only after the host has sent to the client.
