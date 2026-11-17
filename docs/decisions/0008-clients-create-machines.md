# 8. Clients create Viam machines; the server stages credentials

Status: Accepted

Date: 2026-10-02

## Context

In v2, operators provision from client apps against a long-running LAN server. There are two ways to create machines: the server holds a Viam credential and creates machines on request, or each client creates machines with its user's own session and sends the server the results.

## Decision

The client creates machines and fetches each one's credentials with the signed-in user's session. It sends the server only a name and that machine's credential blob. The server never holds a Viam account credential.

## Consequences

- A compromised server exposes the machines currently queued, not an account or org.
- Every client needs Viam API access.
- The server can't provision on its own.

## Alternatives

- The server holds a Viam credential and creates machines on request. The record gives no reason for not choosing it.
