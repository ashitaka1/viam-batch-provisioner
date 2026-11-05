# 46. Tie a TFTP read to a MAC through the client's DHCP request

Date: 2026-11-05

## Status

Accepted; unverified on hardware until #43's run

## Context

Server-observed stages (decision 36) need "boot files sent" per machine. A TFTP request carries only the client's IP address. Proxy DHCP assigns no address, and the offer's `PXE_DISCOVERY_CONTROL` skips the port-4011 exchange, so the server never sees an IP tied to a MAC in its own replies. The firmware's DHCPREQUEST to the lab's DHCP server is broadcast to port 67, where the proxy listens, and names the address in option 50.

## Decision

ProvisionerPXE records the MAC and address of each PXE client's DHCPREQUEST (option 50, else `ciaddr`) in a `LeaseTable` of at most 4096 addresses, and a `fileSent` event carries the MAC recorded for the reader's address, or none.

## Consequences

The mapping is portable and comes from the wire the proxy already reads. A client whose request is unicast, or a DHCP server that acknowledges a different address than requested, yields `fileSent` without a MAC; the event still carries the address and filename. GRUB's per-MAC config names (`grub.cfg-01-<mac>`) identify the machine independently. Reading the kernel's ARP table for the address was the alternative; it needs a platform shim for Linux (decision 34) and an entry exists only after the host has sent to the client.
