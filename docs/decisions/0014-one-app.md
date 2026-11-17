# 14. Ship client and server as one app

Status: Accepted

Date: 2026-10-02

Amended by: [30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)

## Context

v2 needs a client on every operator's device and a server on one Mac per lab. Separate apps mean two distributables and duplicated queue and status views.

Decision 30 amends this record: it moves the server out of the app process.

## Decision

The macOS app is the client and, with a "Host a provisioning server on this Mac" toggle, the server.

## Consequences

- Standing up a server is installing the app and flipping the toggle.
- Server mode reuses the client's views, and the operator can provision from the server Mac.
- Server mode is macOS-only.

## Alternatives

- Ship separate client and server apps. Separate apps mean two distributables and duplicated queue and status views.
