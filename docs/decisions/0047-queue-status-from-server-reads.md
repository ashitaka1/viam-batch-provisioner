# 47. The Mac app's queue takes status from server reads

Date: 2026-11-05

Status: Accepted

## Context

The API derives each entry's status from disk and never from its event stream, and changes made outside the API (`just reset`, `just clean`) emit no events. Queueing machines emits none either.

## Decision

`QueueModel` replaces its entries from `GET /queue` and, for each event not already in the snapshot, from `GET /queue/{name}`. It rereads the whole queue every 15 seconds and after each batch it sends. Every read runs after the one before it.

## Consequences

- The app shows the status the server would report, at the cost of one request per event.
- Machines queued by another client or by the bash tooling appear within 15 seconds.

## Alternatives

- Applying each event to the app's copy of the entry would have duplicated the server's status rules in Swift.
- Waiting for the server to announce queueing with a new event type would need a schema change to both servers and would still miss changes made outside the API.
