# 11. Push events over SSE

Date: 2026-10-02

## Status

Accepted

## Context

Clients make request/response calls (provision, query) and need a push channel for machine events. WebSocket gives a bidirectional channel; Server-Sent Events give a one-way stream over plain HTTP.

## Decision

REST for requests, SSE for events. Clients resume with `Last-Event-ID`.

## Consequences

The REST half stays debuggable with curl, and reconnection is part of the protocol. The server needs a durable event sequence to replay from, which became the journal (decision 22). iOS suspends background SSE connections, so mobile alerts need APNs.
