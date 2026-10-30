# 8. Clients create Viam machines; the server stages credentials

Date: 2026-10-02

## Status

Accepted

## Context

In v2, operators provision from client apps against a long-running LAN server. Either the server holds a Viam credential and creates machines on request, or each client creates machines with its user's own session and sends the server the results.

## Decision

The client creates machines and fetches each one's credentials with the signed-in user's session. It sends the server only a name and a per-machine credential blob. The server never holds a Viam account credential.

## Consequences

A compromised server exposes the machines currently queued, not an account or org. Every client needs Viam API access. The server can't provision on its own.
