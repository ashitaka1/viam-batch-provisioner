# 41. Machine names follow Viam's rule, case-insensitively

Date: 2026-11-03

## Status

Accepted

## Context

The API's `Name` schema used the RFC 1123 label pattern: lowercase, at most 63 characters, no trailing hyphen. The app creates each machine in Viam under the same name before provisioning it, and Viam's own rule (`validateMachineName` in the Viam app, undocumented) differs: letters of either case, digits and hyphens, starting with a letter or digit, at most 60 characters, a trailing hyphen allowed. A name Viam accepts and the server rejects, or the reverse, leaves a machine in one place only. Viam treats names differing only in case as one machine.

## Decision

`Name` in `openapi/provisioner.yaml`, `MachineName` in Swift and `name_problems` in `pxe-watcher/provisioner_service.py` all apply Viam's rule, and each reports one sentence per broken rule. Duplicate detection, within a request and against the queue, ignores case: `slot-<name>` directories on a case-insensitive filesystem would collide.

## Consequences

Names may now contain uppercase letters and be 60 characters long. The installer writes the name verbatim to `/etc/hostname`; a trailing hyphen, which RFC 1123 forbids, is not guarded because batch names end in a digit. Queue lookups by name remain case-sensitive.
