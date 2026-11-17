# 23. Derive entry status from disk

Status: Accepted

Date: 2026-10-04

## Context

`just reset`, `clean` and `unguard` change queue state with no event. A status reduced from the journal would drift from what is on disk.

## Decision

Each read derives `queued`/`flashed`/`assigned`/`installing`/`installed`/`failed` from `queue.json`, `machine-info.json` and the guard file. Completion is `completed_at` in `machine-info.json`. It is stamped before `install-complete` is emitted, because the guard is usually already present from the hostname fetch when the installed machine reboots.

## Consequences

- Disk is the truth, and the journal is a notification stream.
- Clients refetch `/queue` on reconnect and on `resync`.

## Alternatives

None recorded.
