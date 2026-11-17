# 35. Complete an install on the installer's done report

Status: Accepted

Date: 2026-10-31

## Context

`install-complete` meant the machine PXE-booted again after installing and the guard sent it to its disk. A machine whose firmware boots the disk first, such as the UM890 ([Minisforum UM890 BIOS ignores efibootmgr boot order (#4)](https://github.com/ashitaka1/viam-batch-provisioner/issues/4)), never PXE-boots again and stayed `installing` after its installer reported `done`. `install-report.sh` sends `done` at the end of late-commands and retries it.

## Decision

The `done` report stamps `completed_at` and emits `install-complete`. A later PXE boot is the reboot the guard sends to disk and changes nothing.

## Consequences

- Machines complete whichever device their firmware boots first, USB machines included.
- A machine that installs and then fails to boot its disk reads `installed`.

## Alternatives

The record states no reason that these options were not chosen.

- Completing on `done` only after a quiet window with no unguarded PXE.
- Keeping the PXE rule.
