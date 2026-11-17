# 18. Make the watcher stateless and the sole guard writer

Status: Accepted

Date: 2026-10-02

Issue: [HTTP log tailing in just serve doesn't display or create guard files (#2)](https://github.com/ashitaka1/viam-batch-provisioner/issues/2)

## Context

The watcher cached the queue at startup, so provisioning, reset and clean didn't reach a running daemon. Guards were written from two places: the watcher on a repeat PXE, and a log-tailing pipe in `just serve` on a hostname fetch, which failed to fire ([HTTP log tailing in just serve doesn't display or create guard files (#2)](https://github.com/ashitaka1/viam-batch-provisioner/issues/2)).

## Decision

The watcher reads the queue and the MAC's `machine-info.json` on every PXE event. nginx writes `logs/access.log` outside the served tree. A watcher thread follows that log and writes the guard on a 200 hostname fetch, as well as on a repeat PXE more than 60 seconds after assignment. `tail-http-logs.sh` only pretty-prints.

## Consequences

- `just provision`, `reset`, `clean` and `unguard` take effect on a running daemon.
- A MAC that arrives with no slot is not remembered, and it is assigned once the queue has an entry.
- One root process owns guards.

## Alternatives

None recorded.
