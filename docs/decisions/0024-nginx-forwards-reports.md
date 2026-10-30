# 24. Forward installer reports through nginx

Date: 2026-10-06

## Status

Accepted

## Context

Installers must report progress and failure to the server. Targets know one address, the file server's `host:port`, baked into the autoinstall config and, for USB, into each stick's GRUB config. The alternatives:

- **Target calls the API port directly.** No nginx change, but the API port has to be stamped into every config, the whole unauthenticated API is exposed to targets, and the host firewall may prompt for the API's listener.
- **Report through the nginx access log.** A failure encoded in a GET URL and read by the watcher needs no new API surface. Nothing reads the log under `just serve-usb`, the target gets no acknowledgement, and a free-text reason is awkward in a URL.

## Decision

nginx forwards exactly `POST /api/v1/install-reports`, with a 16 KiB body limit, to the API at `host.docker.internal`, which compose maps with `host-gateway`.

## Consequences

The file server's address stays the only one a target needs, and sticks already flashed keep working. The rest of the API (provision, removal, events) stays unreachable from targets. Starting nginx without the recipes' `API_PORT` breaks the forward for a non-default port.
