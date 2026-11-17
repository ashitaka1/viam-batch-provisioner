# 15. Write the v2 server in Swift

Status: Accepted

Date: 2026-10-02

## Context

The v2 server handles UDP PXE and TFTP, HTTP file serving and SSE fan-out, and ships inside the client app, as described in [14. Ship client and server as one app](0014-one-app.md). The current server is Python and bash with nginx in Docker.

## Decision

The server is Swift on SwiftNIO, sharing generated types with the client. The client is built first against the Python Phase 2 server, and the Swift server replaces it after the protocol has proven out.

## Consequences

- The client and server share one language and one set of generated types, and there are no Python, Docker or Homebrew dependencies at runtime.
- The Python server stays in service until Phase 4.

## Alternatives

None recorded.
