# 19. Run the daemons under launchd on the system Python

Date: 2026-10-02

## Status

Accepted

## Context

The always-on server must survive reboots. The project venv lives in the repo and its interpreter may be a version manager's shim that isn't available to root at boot.

## Decision

`scripts/daemon.sh` renders LaunchDaemons from `templates/launchd/`. They run the watcher and API with `/usr/bin/python3` or Homebrew's (≥ 3.9). The serving interface is baked into the plist at install, because default-route detection fails at boot. nginx relies on its compose restart policy and a Docker engine that starts at login; it has no plist.

## Consequences

`pxe-watcher/` uses the standard library only and avoids 3.10-only syntax. Changing the serving interface needs a reinstall. The repo must live outside TCC-protected folders that root can't read.
