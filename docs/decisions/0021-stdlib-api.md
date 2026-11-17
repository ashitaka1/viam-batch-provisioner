# 21. Serve the API on the Python standard library

Status: Accepted

Date: 2026-10-04

## Context

The Phase 2 API runs as a LaunchDaemon under the same interpreter rules as the watcher ([19. Run the daemons under launchd on the system Python](0019-launchd-system-python.md)): system Python, no venv.

## Decision

`pxe-watcher/provisioner_api.py` is a `ThreadingHTTPServer`. Validation is in `provisioner_service.py`, and `test_contract.py` checks real responses against the OpenAPI spec.

## Consequences

- The API runs anywhere the watcher runs.
- Routing, validation and SSE are hand-written.
- The server is interim, and the Swift server replaces it.

## Alternatives

- FastAPI would bring request validation and generated docs, and also a dependency tree that the system Python does not have.
