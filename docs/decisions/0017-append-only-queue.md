# 17. Keep the queue append-only with one locked writer

Date: 2026-10-02

## Status

Accepted

## Context

An always-on server means `just provision` runs while the watcher is live. Provisioning used to error on an existing queue, and the root watcher and the operator's scripts both wrote `queue.json` without coordination.

## Decision

`pxe-watcher/queue_store.py` is the only writer of `queue.json`: an flock on `queue.lock`, temp file plus rename, files chowned to the queue directory's owner. Bash scripts call its CLI. `provision` appends after the highest `<prefix>-N` and skips names already queued; full-mode slot directories are `slot-<name>`. `just clean` is the only wipe.

## Consequences

Batches can be added while the server runs, and two prefixes never collide. Files the root watcher creates stay writable by the operator.
