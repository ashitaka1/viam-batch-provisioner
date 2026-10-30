# Architecture

## Overview

A macOS host provisions x86 machines over the network and Raspberry Pis from SD cards. The host runs four services: dnsmasq (proxy DHCP + TFTP), nginx in Docker (HTTP), a root watcher that binds PXE clients to queued machine names, and an operator-owned REST + SSE API. Bash scripts behind `just` recipes create the queue, stage credentials and flash media. Python under `pxe-watcher/` owns all shared state.

### Boot chains

**x86 PXE.** UEFI PXE ROM → dnsmasq (proxy DHCP + TFTP) → GRUB → Ubuntu kernel + initrd over TFTP → installer downloads the ISO over HTTP → autoinstall → late-commands fetch hostname and credentials by MAC → first boot with viam-agent and Tailscale.

**x86 USB stick.** UEFI USB boot → GRUB on the stick → kernel + initrd from the stick → installer downloads the ISO from the `IP:port` in the stick's `grub.cfg` → autoinstall → late-commands read `viam_hostname=` from `/proc/cmdline` and fetch credentials from `/machines/by-name/<name>/` → first boot. Only the HTTP server and API run.

**Raspberry Pi.** `flash-pi-sd.sh` writes the OS image, mounts the FAT32 boot partition and writes cloud-init `user-data`, `network-config` and `meta-data`. First boot configures the OS offline, then a systemd service does the network-dependent setup (packages, viam-agent, Tailscale).

## Codemap

| Path | Role |
|------|------|
| `justfile` | Operator commands; every workflow starts here |
| `netboot/dnsmasq.conf` | Proxy DHCP + TFTP config; carries no `dhcp-range` |
| `netboot/grub/grub.cfg` | Network GRUB menu; sources `provisioned/<MAC>.cfg` guards |
| `templates/user-data.tpl` | PXE and USB autoinstall config; late-commands and `error-commands` |
| `templates/usb-grub.cfg.tpl` | Per-stick GRUB config with server address and `viam_hostname=` |
| `templates/pi-user-data.tpl` | Pi cloud-init user-data |
| `templates/launchd/*.plist.tpl` | LaunchDaemons for dnsmasq, watcher, API and Bonjour |
| `http-server/default.conf.template` | nginx config; forwards exactly `POST /api/v1/install-reports` to the API. Rendered at container start; only `API_PORT` is substituted |
| `http-server/scripts/install-report.sh` | POSIX script the installer fetches and runs to report progress or failure; always exits 0 |
| `openapi/provisioner.yaml` | The API contract |
| `pxe-watcher/watcher.py` | Root watcher. `PxeTracker` assigns names to MACs; `LogTailer` follows the nginx access log and writes guards; a sweep thread fails silent installs every 30 seconds. `update_info` is the locked writer of `machine-info.json` |
| `pxe-watcher/queue_store.py` | Sole writer of `queue.json`; library for Python, CLI for the bash scripts |
| `pxe-watcher/event_journal.py` | Appends lifecycle events to `logs/events.jsonl` |
| `pxe-watcher/event_hub.py` | API-side tailer of the journal: ring buffer, `events_after(cursor)`, resync detection |
| `pxe-watcher/provisioner_service.py` | Request validation, credential staging, derived entry status, removal, `report_install` |
| `pxe-watcher/provisioner_api.py` | Stdlib `ThreadingHTTPServer` implementing the contract (REST + SSE) on `API_PORT` |
| `scripts/provision-batch.sh` | Appends machines to the queue; in full mode creates them in Viam and stages credentials (`fetch-credentials.py`) |
| `scripts/build-config.sh` | Renders `http-server/autoinstall/user-data` from `templates/user-data.tpl` |
| `scripts/setup-pxe-server.sh` | Extracts GRUB, kernel and initrd from the Ubuntu ISO (`just setup`) |
| `scripts/daemon.sh` | Renders the plists and installs, removes and reports on the LaunchDaemons |
| `scripts/api-service.sh` | Starts and stops the API and `dns-sd -R` in foreground mode via pid files in `logs/` |
| `scripts/lib/site-env.sh` | Reads settings from `config/site.env` without sourcing it; defaults `API_PORT`/`HTTP_PORT`/`INSTALL_TIMEOUT_MINUTES` to 8235/8234/45 |
| `scripts/pxe-subnet.sh` | Prints dnsmasq's proxy range for an interface, or for `PXE_PROXY_SUBNET` |
| `scripts/pick-server-iface.sh` | Scores UP IPv4 interfaces: default route first, then wired over wireless |
| `scripts/flash-pi-sd.sh`, `flash-batch.sh` | Pi SD card flashing |
| `scripts/flash-usb.sh`, `flash-usb-batch.sh` | x86 USB stick flashing |
| `scripts/tail-http-logs.sh` | Pretty-prints `logs/access.log` (`just logs`); writes nothing |
| `scripts/setup-wizard.sh` | Creates `config/site.env` and per-environment files |

## Data model

All under `http-server/machines/` unless noted. Every file the root watcher creates is chowned to the owner of that directory.

- **`queue.json`** — array of entries, written only by `queue_store.py` under an flock on `queue.lock` with temp-file-and-rename. `{"name", "assigned"}`; full mode adds `slot_id` (`slot-<name>`); PXE assignment adds `mac`; USB flashing adds `flashed_via`. A USB machine's failure markers live on its entry.
- **`slot-<name>/viam.json`** — full-mode credentials staged at provision time, before a MAC is known.
- **`<mac>/machine-info.json`** — one PXE machine: `name`, `mac`, `assigned_at`, `attempt`, `progress_at`, `completed_at`, `failed_at`/`failure_reason`/`failure_source` (`installer`, `timeout` or `reboot`), `armed`. Every change to an existing file goes through `watcher.update_info` (flock on `info.lock`).
- **`by-name/<name>/`** — credentials for USB machines, which fetch by name.
- **`netboot/grub/provisioned/<MAC>.cfg`** — the guard. Its presence makes GRUB exit to disk instead of installing.
- **`logs/events.jsonl`** — the event journal. Ids derive from the last line, read under the file's flock.
- **`logs/access.log`** — nginx's access log, mounted at `/var/log/pxe`, outside the served tree.
- **`config/site.env`** — site settings, gitignored. `config/.server-address` holds the `IP:port` baked into USB sticks.

## Invariants

- **`queue.json` has one writer.** Scripts call `queue_store.py`'s CLI; the watcher and API import it.
- **The queue is append-only.** `provision` adds machines after the highest existing `<prefix>-N` and skips names already queued. `just clean` is the only wipe.
- **The watcher holds no state in memory.** It reads the queue and the MAC's `machine-info.json` on every PXE event, so `provision`, `reset`, `clean` and `unguard` take effect on a running daemon. A MAC that arrives with no slot is not remembered.
- **One process writes guards.** The watcher writes a guard on a 200 response to `GET /machines/<mac>/hostname` in the access log, and on a repeat PXE more than 60 seconds after assignment.
- **The journal is the only IPC.** The root watcher and the operator-owned API both append to `logs/events.jsonl` under its flock; the API tails it for SSE. A journal write failure is logged and never blocks assignment, guards or a recorded failure.
- **Entry status comes from disk.** `queued`/`flashed`/`assigned`/`installing`/`installed`/`failed` derive from `queue.json`, `machine-info.json` and the guard on every read. `failed` is checked first, because a failure removes the guard and a missing guard alone reads as `assigned`. `install-complete` is decided by `completed_at`, stamped before the event is emitted.
- **Crash recovery completes, never re-assigns.** The watcher completes an entry already assigned to a MAC instead of consuming a second slot.
- **A failure removes the guard; the next PXE starts a new attempt.** A failed or `armed` MAC gets `attempt` + 1, a reset `assigned_at` and cleared markers, before the 60-second repeat-PXE rule is consulted. An installer failure replaces a timeout failure and then sticks; a timeout failure is cleared by later progress or a hostname fetch. A USB machine has no re-arm, so any progress after its failure clears it.
- **A repeat PXE with no sign of the installer is a failed boot.** Past the 60-second window, a machine with no progress report and no hostname-fetch guard records `install-failed` with source `reboot` and starts a new attempt. Machines assigned before attempts existed (no `attempt`) keep the old completion rule.
- **`done` exempts from the timeout; it does not complete.** `install-complete` means the machine PXE-booted again after installing.
- **Installer reports carry no log text.** A reason is a fixed phrase plus at most the crash exception class, cleaned by the helper and again by the server.
- **The timeout is off unless passed.** The watcher's `--install-timeout-minutes` defaults to off; `just serve` and the plist pass `INSTALL_TIMEOUT_MINUTES`.
- **Daemons run on a stable interpreter.** System or Homebrew `python3` ≥ 3.9, never the venv; the code avoids 3.10-only syntax. The serving interface is baked into the plist at install. dnsmasq is stopped by pid file.
- **dnsmasq's proxy range follows the serving interface**, computed by `pxe-subnet.sh` at `just serve` or daemon install. `PXE_PROXY_SUBNET` overrides it.
- **NIC names are discovered at install time.** The autoinstall config hardcodes no interface names.

## Boundaries

- **Targets reach only the file server.** They know one `host:port`. nginx forwards exactly `POST /api/v1/install-reports` (16 KiB body limit) to the API at `host.docker.internal`; the rest of the API is unreachable from a target.
- **The API runs as the operator, unauthenticated, on `0.0.0.0`.** It assumes a trusted lab network. It skips `getfqdn()` at bind so startup never waits on reverse DNS.
- **The org API key stays on the host.** Targets receive only their own `viam.json`.
- **Under `just serve-usb` no watcher runs.** The API appends installer reports to the journal itself.

## API

`openapi/provisioner.yaml` is the contract. `pxe-watcher/test_contract.py` validates real responses and journal events against it. Every SSE frame's `data` carries `id`, `type` and `timestamp`. `GET /queue` returns `last_event_id` for snapshot-then-stream; a `resync` event means the client's `Last-Event-ID` can't be served and it should refetch `/queue`. The API advertises `_viam-provisioner._tcp` over Bonjour with `api=v1` in the TXT record.

## Boot order after install

The installer moves the disk above network boot with `efibootmgr`, from late-commands and again from a first-boot service, because efivars are not always writable in the installer chroot. Some firmware restores network-first anyway (#4); every reboot then network-boots and the guard sends it to disk. A machine whose firmware boots the disk first never PXEs again after install, so it stays `installing`.
