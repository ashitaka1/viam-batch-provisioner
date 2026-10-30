# 2. Fetch per-machine credentials with an org-scoped key

Date: 2026-03-27

## Status

Accepted

## Context

A full-mode machine needs its own Viam cloud credentials (part ID and secret) on first boot. The options were to put an API key on each target and let it register itself, or to create machines and fetch their credentials on the operator's host and hand each target only its own.

## Decision

An org-scoped API key in `config/site.env` creates machines with the Viam CLI and fetches each machine's `viam.json` through the Python SDK (`scripts/fetch-credentials.py`). The file is staged on the HTTP server and fetched by the target during late-commands.

## Consequences

The org key never leaves the host. A compromised target exposes only its own credentials. Full mode needs the Viam CLI and a venv with `viam-sdk` on the host. Staged credentials sit on an unauthenticated LAN file server until provisioning ends.
