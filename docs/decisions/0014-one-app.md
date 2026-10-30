# 14. Ship client and server as one app

Date: 2026-10-02

## Status

Accepted; amended by decision 30, which moves the server out of the app process

## Context

v2 needs a client on every operator's device and a server on one Mac per lab. Separate apps mean two distributables and duplicated queue and status views.

## Decision

The macOS app is the client and, with a "Host a provisioning server on this Mac" toggle, the server.

## Consequences

Standing up a server is installing the app and flipping the toggle. Server mode reuses the client's views, and the operator can provision from the server Mac. Server mode is macOS-only.
