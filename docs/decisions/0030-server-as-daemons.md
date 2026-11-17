# 30. Run server mode as launch daemons with a menu bar client

Status: Accepted

Amended by: [50. Server mode is one unprivileged daemon that answers PXE itself](0050-one-server-daemon.md)

Date: 2026-10-30

## Context

A lab's server Mac must serve from boot, before anyone logs in, and keep serving whether or not the app is open. [14. Ship client and server as one app](0014-one-app.md) put the server inside the app, and [13. Answer PXE natively in the v2 server](0013-native-pxe.md) put PXE and TFTP in a privileged helper.

[50. Server mode is one unprivileged daemon that answers PXE itself](0050-one-server-daemon.md) amends this record: server mode is one daemon, `ProvisionerServer`, which hosts PXE itself.

## Decision

Server mode is two launch daemons registered with `SMAppService`, both `RunAtLoad` and `KeepAlive`:

- `ProvisionerHelper` runs as root and hosts PXE and TFTP ([13. Answer PXE natively in the v2 server](0013-native-pxe.md)).
- `ProvisionerServer` runs headless as an unprivileged user (`UserName`) and hosts HTTP, REST/SSE, the queue, templating and Bonjour.

A menu bar item, which is a login item, shows each background service's status and turns each on or off. It reads the server through the same REST/SSE API as every other client. Quitting the menu bar item or the app stops nothing.

## Consequences

- The server returns after a reboot without a login, and launchd restarts a crashed service.
- The helper's XPC peer is the server daemon.
- The app's "Host a provisioning server on this Mac" toggle registers both daemons, and the user approves them once in System Settings.

## Alternatives

- A user LaunchAgent starts only at login.
