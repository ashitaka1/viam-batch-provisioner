# 22. Use an append-only journal as the only IPC

Date: 2026-10-04

## Status

Accepted

## Context

Events originate in the root watcher and, for installer reports, in the operator-owned API. The API serves them over SSE with replay from `Last-Event-ID`. A socket between the two processes would need a protocol, a privilege boundary and reconnection handling, and would lose events while the API is down.

## Decision

Both processes append to `logs/events.jsonl` under its flock; ids derive from the last line. The API tails the file (`event_hub.py`) into a ring buffer for SSE.

## Consequences

Events survive restarts of either process, and replay reads the file. A journal write failure is logged and never blocks assignment, guards or a recorded failure. A client whose cursor is older than the retained history gets `resync`.
