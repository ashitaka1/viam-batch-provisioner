# 21. Serve the API on the Python standard library

Date: 2026-10-04

## Status

Accepted

## Context

The Phase 2 API runs as a LaunchDaemon under the same interpreter rules as the watcher (decision 19): system Python, no venv. FastAPI would bring request validation and generated docs, and a dependency tree that interpreter doesn't have.

## Decision

`pxe-watcher/provisioner_api.py` is a `ThreadingHTTPServer`. Validation lives in `provisioner_service.py`, and `test_contract.py` checks real responses against the OpenAPI spec.

## Consequences

The API runs anywhere the watcher runs. Routing, validation and SSE are hand-written. The server is interim; the Swift server replaces it.
