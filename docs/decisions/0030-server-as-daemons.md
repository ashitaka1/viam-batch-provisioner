# 30. Run server mode as launch daemons with a menu bar client

Date: 2026-10-30

## Status

Accepted

## Context

A lab's server Mac must serve from boot, before anyone logs in, and keep serving whether or not the app is open. Decision 14 put the server inside the app, and decision 13 put PXE and TFTP in a privileged helper.

## Decision

Server mode is two launch daemons registered with `SMAppService`, both `RunAtLoad` and `KeepAlive`:

- `ProvisionerHelper` runs as root and hosts PXE and TFTP (decision 13).
- `ProvisionerServer` runs headless as an unprivileged user (`UserName`) and hosts HTTP, REST/SSE, the queue, templating and Bonjour.

A menu bar item, a login item, shows each background service's status and turns each on or off. It reads the server through the same REST/SSE API as every other client. Quitting it or the app stops nothing.

## Consequences

The server returns after a reboot without a login, and launchd restarts a crashed service. The helper's XPC peer is the server daemon. The app's "Host a provisioning server on this Mac" toggle registers both daemons, and the user approves them once in System Settings. A user LaunchAgent was the alternative; it starts only at login.
