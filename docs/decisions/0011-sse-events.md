# 11. Push events over SSE

Status: Accepted

Date: 2026-10-02

## Context

Clients make request/response calls (provision, query) and need a push channel for machine events. WebSocket gives a bidirectional channel, and Server-Sent Events give a one-way stream over plain HTTP.

## Decision

REST carries requests and SSE carries events. Clients resume with `Last-Event-ID`.

## Consequences

- The REST half stays debuggable with curl, and reconnection is part of the protocol.
- The server needs a durable event sequence to replay from, which became the journal described in [22. Use an append-only journal as the only IPC](0022-event-journal.md).
- iOS suspends background SSE connections, so mobile alerts need APNs.

## Alternatives

- WebSocket, which gives a bidirectional channel. The record gives no reason for not choosing it.
