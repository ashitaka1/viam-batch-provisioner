# Viam Batch Provisioner

Zero-touch provisioning for x86 Linux machines (PXE or USB stick) and Raspberry Pis (SD card) as Viam robotics hosts.

Tracking: GitHub issues (ashitaka1/viam-batch-provisioner); project ashitaka1/4; auto-add ashitaka1/viam-batch-provisioner

- `README.md` — usage, configuration, provision modes, known issues
- `CONTRIBUTING.md` — setup, test, running services alone, hardware validation
- `ARCHITECTURE.md` — boot chains, codemap, data model, invariants, boundaries
- `docs/decisions/` — one decision per file
- `openapi/provisioner.yaml` — the API contract; `pxe-watcher/test_contract.py` validates the server against it

The v2 rewrite (Swift server + SwiftUI client) is tracked as milestones and issues. The bash/Python tooling is the working system until the Swift server replaces it; don't break it.

## Commands

```bash
just test               # unittest discover -s pxe-watcher (prefers .venv/bin/python3)
just serve              # HTTP + DHCP/TFTP + watcher + API in the foreground
just serve-usb          # HTTP + API only
just serve-daemon       # install the LaunchDaemons (sudo)
just daemon-status
just api                # API alone on API_PORT (8235)
```

## Invariants

The full list is in `ARCHITECTURE.md`. The ones that bite when editing:

- `queue.json` is written only through `pxe-watcher/queue_store.py`. Bash scripts call its CLI.
- Every change to an existing `machine-info.json` goes through `watcher.update_info` (flock on `info.lock`); the root watcher and the operator-run API both write it.
- The watcher keeps no state in memory. Read the queue and `machine-info.json` per event.
- Entry status is derived from disk on every read. Check `failed` before the guard, because a failure removes the guard.
- Journal (`logs/events.jsonl`) write failures are logged and never block assignment, guards or a recorded failure.
- Files the root watcher creates are chowned to the owner of `http-server/machines/`.
- Installer reports never carry log text; the WiFi password is in a late-command.
- `user-data.tpl` serves both PXE and USB: late-commands read `viam_hostname=` from the cmdline first and fall back to MAC lookup.
- `dnsmasq.conf` carries no `dhcp-range`; `scripts/pxe-subnet.sh` supplies it.

## Gotchas

- The daemons run `/usr/bin/python3` or Homebrew's (≥ 3.9), never the venv. `pxe-watcher/` uses only the standard library and no 3.10-only syntax.
- dnsmasq is stopped by pid file, never `killall`.
- `scripts/lib/site-env.sh` reads `config/site.env` without sourcing it. Defaults: `API_PORT` 8235, `HTTP_PORT` 8234, `INSTALL_TIMEOUT_MINUTES` 45.
- The watcher's own `--install-timeout-minutes` defaults to off; `just serve` and the plist pass the setting.
- nginx's config is `http-server/default.conf.template`, rendered at container start with only `API_PORT` substituted. Start nginx with `just up`, not bare `docker compose up`, so a custom `API_PORT` reaches it.
- `just serve` refuses to run while the LaunchDaemons are installed.
- Anything calling sudo hangs in the agent shell; ask the user to run it.
- Changing the boot chain, autoinstall config, watcher or install reports needs validation on real hardware (see `CONTRIBUTING.md`).
