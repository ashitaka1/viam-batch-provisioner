# 7. Lay out USB sticks as one FAT32 ESP on GPT

Date: 2026-04-30

## Status

Accepted

## Context

A stick must boot on any UEFI machine without creating a firmware boot entry for it first.

## Decision

The stick is GPT with a single FAT32 EFI system partition. GRUB is installed at `/EFI/BOOT/BOOTX64.EFI`, the UEFI removable-media fallback path.

## Consequences

Any UEFI firmware boots the stick from its one-time boot menu. macOS writes the whole stick with `diskutil eraseDisk`. Legacy BIOS boot is not supported.
