# 12. Define the protocol in OpenAPI

Date: 2026-10-02

## Status

Accepted

## Context

v2 client and server are both Swift, and the contract between them should fail the build when it drifts. Swift distributed actors give compile-checked remote calls but lock both ends to Swift. The interim server (Phase 2) is Python.

## Decision

`openapi/provisioner.yaml` is the contract. Swift client and server stubs are generated from it with `swift-openapi-generator`; the Python server is validated against it by `test_contract.py`.

## Consequences

Drift is a build error on the Swift side and a test failure on the Python side. The spec is hand-written and versioned with the code. Non-Swift clients remain possible.
