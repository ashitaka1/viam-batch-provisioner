# 26. Reinstall a failed machine on its next PXE boot

Status: Accepted

Date: 2026-10-06

## Context

A failed install should be retryable by network-booting the machine again. The 60-second repeat-PXE rule would read a later boot as a finished install, and `just unguard` only worked inside that window.

## Decision

A failure (installer report or timeout) stamps `failed_at`/`failure_reason`/`failure_source` and removes the guard. The next PXE sighting of a failed or `armed` MAC starts a new attempt (`attempt` + 1, `assigned_at` reset, markers cleared) before the repeat-PXE rule is consulted. `just unguard` sets `armed`. An installer failure replaces a timeout failure and then sticks. Later progress or a hostname fetch clears a timeout failure. A USB machine has no re-arm, so a progress report after its failure clears it.

## Consequences

- Retry is a reboot, however long after the failure.
- A forged report can mark a machine still installing as failed, so it reinstalls on its next PXE boot.
- Completed machines are unaffected by a forged report.

## Alternatives

None recorded.
