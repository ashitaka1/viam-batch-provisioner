# 2. Fetch each machine's credentials with an org-scoped key

Status: Accepted

Date: 2026-03-27

## Context

A full-mode machine needs its own Viam cloud credentials (part ID and secret) on first boot. There are two ways to supply them: put an API key on each target and let it register itself, or create machines and fetch their credentials on the operator's host and hand each target only its own.

## Decision

An org-scoped API key in `config/site.env` creates machines with the Viam CLI. The Python SDK fetches each machine's `viam.json` (`scripts/fetch-credentials.py`). The file is staged on the HTTP server, and the target fetches it during late-commands.

## Consequences

- The org key never leaves the host.
- A compromised target exposes only its own credentials.
- Full mode needs the Viam CLI and a venv with `viam-sdk` on the host.
- Staged credentials sit on an unauthenticated LAN file server until provisioning ends.

## Alternatives

- Put an API key on each target and let it register itself. The record gives no reason for not choosing it.
