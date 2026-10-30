# 23. Derive entry status from disk

Date: 2026-10-04

## Status

Accepted

## Context

`just reset`, `clean` and `unguard` change queue state with no event. Status reduced from the journal would drift from what's on disk.

## Decision

Each read derives `queued`/`flashed`/`assigned`/`installing`/`installed`/`failed` from `queue.json`, `machine-info.json` and the guard file. Completion is `completed_at` in `machine-info.json`, stamped before `install-complete` is emitted, because the guard is usually already present from the hostname fetch when the installed machine reboots.

## Consequences

Disk is the truth, and the journal is a notification stream. Clients refetch `/queue` on reconnect and on `resync`.
