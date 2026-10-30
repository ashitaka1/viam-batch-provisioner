# 5. Reset boot order to disk-first after install

Date: 2026-04-17

## Status

Accepted

## Context

Targets are set to network-boot first so they PXE without a keypress. After install they would network-boot on every power-on. The server-side guard stops a reinstall, but the machine still depends on the PXE server being up to reach its disk.

## Decision

`fix-boot-order.sh` moves the installed disk above network boot with `efibootmgr`. It runs in-target from late-commands and again from a first-boot service, because efivars are not always writable in the installer chroot.

## Consequences

Machines whose firmware honors `BootOrder` boot from disk after install. Some firmware ignores it (#4), and the guard remains the safety net. A disk-first machine never PXEs again after install, so the server can't observe its completion.
