# 3. Network-boot with GRUB from the Ubuntu ISO

Status: Accepted

Date: 2026-03-31

## Context

The first boot chain used netboot.xyz and iPXE. That chain adds a second bootloader with its own menu and assets. The Ubuntu ISO ships a signed GRUB that can boot over the network directly.

## Decision

dnsmasq serves GRUB extracted from the Ubuntu ISO (`just setup`). GRUB loads the kernel and initrd over TFTP and points the installer at the ISO over HTTP.

## Consequences

- The chain has one bootloader, and it comes from the same ISO as the installer.
- The binaries are extracted per host and kept out of git.
- A guard file for each MAC in `netboot/grub/provisioned/` can stop a provisioned machine from reinstalling, because `grub.cfg` sources the guard files.

## Alternatives

- Keep the netboot.xyz and iPXE chain. That chain adds a second bootloader with its own menu and assets.
