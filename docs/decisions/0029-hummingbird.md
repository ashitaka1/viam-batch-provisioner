# 29. Serve HTTP with Hummingbird

Date: 2026-10-30

## Status

Accepted

## Context

`ProvisionerServer` serves files, REST from `swift-openapi-generator` server stubs, and SSE, on SwiftNIO (decision 15), in a process that also hosts other services (decision 30). Hummingbird and Vapor both have an OpenAPI transport.

## Decision

The server uses Hummingbird 2 with `swift-openapi-hummingbird`.

## Consequences

The HTTP application runs as one `swift-service-lifecycle` service among others in its process, and SSE is a streamed response body. Vapor was the alternative: a larger ecosystem (Fluent, Leaf, auth middleware) the server doesn't use, and it assumes ownership of the process through its `Environment` and command parsing.
