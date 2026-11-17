# 19. Run the daemons under launchd on the system Python

Status: Accepted

Date: 2026-10-02

## Context

The always-on server must survive reboots. The project's venv is in the repo, and its interpreter may be a version manager's shim that is not available to root at boot.

## Decision

`scripts/daemon.sh` renders LaunchDaemons from `templates/launchd/`. The LaunchDaemons run the watcher and the API with `/usr/bin/python3` or with Homebrew's Python, version 3.9 or later. The serving interface is baked into the plist at install, because default-route detection fails at boot. nginx relies on its compose restart policy and on a Docker engine that starts at login. It has no plist.

## Consequences

- `pxe-watcher/` uses only the standard library and avoids syntax that requires Python 3.10.
- Changing the serving interface needs a reinstall.
- The repo must live outside TCC-protected folders that root cannot read.

## Alternatives

None recorded.
