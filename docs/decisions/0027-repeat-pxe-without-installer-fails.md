# 27. Treat a repeat PXE with no installer activity as a failed boot

Date: 2026-10-06

## Status

Accepted

## Context

On the testbed, Secure Boot rejected GRUB, the firmware fell through to the old disk, and the next network boot was counted as a finished install.

## Decision

A repeat PXE past the 60-second window from a machine whose installer never reported progress and never fetched its hostname records `install-failed` with source `reboot` and starts a new attempt. Machines assigned before attempts existed keep the old completion rule.

## Consequences

Boots that never reached the installer show as failures. A good install whose every report and hostname fetch were lost is reinstalled on its next PXE boot.
