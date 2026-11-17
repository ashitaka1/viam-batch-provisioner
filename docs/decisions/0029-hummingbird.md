# 29. Serve HTTP with Hummingbird

Status: Accepted

Date: 2026-10-30

## Context

`ProvisionerServer` serves files, REST from `swift-openapi-generator` server stubs, and SSE, on SwiftNIO ([15. Write the v2 server in Swift](0015-swift-server.md)), in a process that also hosts other services ([30. Run server mode as launch daemons with a menu bar client](0030-server-as-daemons.md)). Hummingbird and Vapor both have an OpenAPI transport.

## Decision

The server uses Hummingbird 2 with `swift-openapi-hummingbird`.

## Consequences

- The HTTP application runs as one `swift-service-lifecycle` service among others in its process.
- SSE is a streamed response body.

## Alternatives

- Vapor has a larger ecosystem (Fluent, Leaf, auth middleware) that the server does not use, and it assumes ownership of the process through its `Environment` and command parsing.
