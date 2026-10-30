# 15. Write the v2 server in Swift

Date: 2026-10-02

## Status

Accepted

## Context

The v2 server handles UDP PXE and TFTP, HTTP file serving and SSE fan-out, and ships inside the client app (decision 14). The current server is Python and bash with nginx in Docker.

## Decision

The server is Swift on SwiftNIO, sharing generated types with the client. The client is built first against the Python Phase 2 server; the Swift server replaces it after the protocol has proven out.

## Consequences

One language and one set of generated types across client and server, and no Python, Docker or Homebrew dependencies at runtime. The Python server stays in service until Phase 4.
