# Viam Batch Provisioner

Zero-touch provisioning for x86 Linux machines (PXE or USB stick) and Raspberry Pis (SD card) as Viam robotics hosts.

## v2 Direction

A client-server rewrite (Swift server + SwiftUI client apps, REST + SSE from an OpenAPI contract) is planned in `docs/architecture-v2.md`, including phasing and open questions. Read it before starting new feature work. The existing bash/Python tooling below remains the working system until v2 replaces it — don't break it.

Phase 1 (persistent server on the current stack) is complete and validated live (2026-10-03): stateless watcher, append-only queue via `queue_store.py`, launchd daemons, proxy-DHCP range derived from the serving interface via `scripts/pxe-subnet.sh`. Phase 2 (OpenAPI contract + Python REST/SSE + Bonjour) is implemented and validated against a running server (2026-10-04): `openapi/provisioner.yaml` is the contract, `pxe-watcher/provisioner_api.py` serves it on the standard library, and the watcher journals lifecycle events to `logs/events.jsonl`. Install-failure detection (installer reports, a `failed` status, retry, and a timeout) is implemented and validated on a PXE testbed (2026-10-06): a forced late-command failure, the retry, a Secure Boot failed boot, and `just unguard` all behaved as designed on real hardware. Phase 3 (Swift shared library + macOS client) is next.

## Configuration

All site-specific settings live in `config/site.env` (gitignored). Run `just setup-wizard` to create it interactively. Settings include: machine prefix/count, username/password, WiFi, SSH key, Viam Cloud credentials (optional), Tailscale (optional).

Three provision modes:
- **full** — creates machines in Viam, installs viam-agent, deploys credentials
- **agent** — installs viam-agent binary, user adds credentials themselves
- **os-only** — just configures the OS, no Viam software

## Architecture

### x86 PXE Boot Chain

UEFI PXE ROM → dnsmasq (proxy DHCP + TFTP) → GRUB → Ubuntu kernel + initrd via TFTP → installer downloads ISO via HTTP → Ubuntu autoinstall → late-commands fetch identity + credentials → first boot with viam-agent + Tailscale

### x86 USB Stick Boot Chain

UEFI USB boot → GRUB on stick → kernel + initrd from stick → installer downloads ISO via HTTP at the IP baked into grub.cfg → Ubuntu autoinstall → late-commands read `viam_hostname=` from kernel cmdline and fetch credentials from `/machines/by-name/<name>/` → first boot. No DHCP proxy, no TFTP, no PXE watcher — only the HTTP server runs. Use this when multiple operators share a network (PXE proxies would conflict) or when the LAN's DHCP server is locked down.

### Raspberry Pi SD Card

`flash-pi-sd.sh` writes OS image → mounts FAT32 boot partition → writes cloud-init user-data, network-config, meta-data → first boot runs Phase 2 service for network-dependent setup (packages, viam-agent, Tailscale)

### Components

- **dnsmasq** (native, not Docker) — proxy DHCP + TFTP for PXE boot
- **nginx** (Docker) — HTTP server for ISO, autoinstall configs, credentials; forwards exactly `POST /api/v1/install-reports` to the host API. Its config is `http-server/default.conf.template`, bind-mounted and rendered at container start (only `API_PORT` is substituted)
- **http-server/scripts/install-report.sh** — the POSIX script the installer fetches and runs to report progress or failure; always exits 0
- **pxe-watcher** (host script, root) — assigns names to MACs as machines PXE boot; tails the nginx access log and writes GRUB guards on hostname fetch or repeat PXE; a thread sweeps every 30 seconds and fails silent installs (`--install-timeout-minutes`)
- **pxe-watcher/queue_store.py** — sole writer of `queue.json` (flock + atomic replace); imported by the watcher and the API, called as a CLI by the bash scripts
- **pxe-watcher/event_journal.py** — append-only `logs/events.jsonl` written by the watcher and the API (installer reports); ids derived from the last line under an flock
- **pxe-watcher/event_hub.py** — API-side tailer of the journal: ring buffer, `events_after(cursor)`, resync detection
- **pxe-watcher/provisioner_service.py** — request validation, credential staging via `queue_store.append(stage=)`, disk-derived entry status, removal, install-report handling (`report_install`)
- **pxe-watcher/provisioner_api.py** — stdlib `ThreadingHTTPServer` implementing `openapi/provisioner.yaml` (REST + SSE); runs as the operator on `API_PORT` (8235)
- **scripts/api-service.sh** — starts/stops the API and `dns-sd -R` in foreground mode (`just serve`, `just serve-usb`) via pid files in `logs/`
- **scripts/lib/site-env.sh** — sourced by `api-service.sh` and `daemon.sh`; reads settings from `config/site.env` without sourcing it, and defaults `API_PORT`/`HTTP_PORT`/`INSTALL_TIMEOUT_MINUTES` (8235/8234/45)
- **scripts/daemon.sh** — renders `templates/launchd/*.plist.tpl` and installs dnsmasq, watcher, API and Bonjour as LaunchDaemons
- **scripts/tail-http-logs.sh** — pretty-prints `logs/access.log` (`just logs`); writes nothing
- **provision-batch.sh** — creates Viam machines + fetches credentials (full mode), or generates names-only queue (os-only/agent mode); appends to the existing queue
- **flash-pi-sd.sh** / **flash-batch.sh** — SD card flashing for Pis
- **flash-usb.sh** / **flash-usb-batch.sh** — x86 USB boot stick flashing (per-machine, fixed server)
- **pick-server-iface.sh** — scores host network interfaces; used by USB flash + serve-usb
- **pxe-subnet.sh** — prints the dnsmasq proxy-DHCP range for an interface, or for `PXE_PROXY_SUBNET` from `config/site.env`; used by `just serve` and `daemon.sh install`
- **build-config.sh** — generates PXE autoinstall user-data from template
- **setup-wizard.sh** — interactive config creation

### Key Design Decisions

- **GRUB, not netboot.xyz/iPXE.** GRUB handles network boot directly from the Ubuntu ISO's signed binary.
- **dnsmasq runs natively.** Docker Desktop for Mac can't do host networking for broadcast DHCP/TFTP.
- **Proxy-DHCP range follows the serving interface.** `dnsmasq.conf` carries no `dhcp-range`; `pxe-subnet.sh` derives `<network>,proxy,<netmask>` from the interface at `just serve` or daemon install time. `PXE_PROXY_SUBNET` (CIDR) in `site.env` overrides it.
- **NIC names discovered at install time.** Dynamic detection, no hardcoded interface names.
- **Provisioning key pattern.** Org-scoped API key fetches per-machine cloud credentials via Python SDK. The org key never touches target machines.
- **Pi OS uses cloud-init.** Pi OS Trixie has native cloud-init on the boot partition (FAT32, mountable from macOS). Two-phase boot: offline config first, network-dependent setup via systemd service.
- **Boot order reset after PXE install.** `efibootmgr` moves disk above network boot.
- **USB mode bakes identity into the bootloader.** Each stick's `grub.cfg` carries the host's `IP:port` and `viam_hostname=<name>` on the kernel cmdline, so the installer doesn't need a DHCP-watcher to learn its identity. Credentials are pre-staged at `/machines/by-name/<name>/viam.json` at flash time. The `user-data.tpl` late-commands try the cmdline first and fall back to MAC lookup, so the same template serves both modes.
- **USB layout: single FAT32 ESP, GPT.** GRUB is installed at `/EFI/BOOT/BOOTX64.EFI` (UEFI fallback path) so the stick boots on any UEFI firmware without per-machine boot entries.
- **Best-interface picker.** `pick-server-iface.sh` enumerates UP IPv4 interfaces, prefers the default-route one, then wired (`en*`/`eth*`/`enp*`) over wireless. Operator confirms the choice once per batch.
- **Server address persisted between flash and serve.** `flash-usb-batch.sh` writes the chosen `IP:port` to `config/.server-address` (gitignored). `just serve-usb` reads it so `build-config.sh` stamps the same address into `user-data` that's baked into the sticks.
- **The watcher holds no state in memory.** The queue is read from `queue.json` on every PXE event and a MAC's assignment time comes from its `machine-info.json`, so `just provision`, `just reset` and `just clean` take effect on a running daemon. A MAC that arrives with no slot is not remembered; it is assigned once the queue has an entry.
- **Append-only queue.** `provision` adds `COUNT` machines after the highest existing `<prefix>-N`; names already queued are skipped. `just clean` is the only wipe. Full-mode slot dirs are `slot-<name>` so two prefixes never collide.
- **One guard writer.** nginx writes its access log to `logs/access.log` (mounted at `/var/log/pxe`, outside the served `/srv` tree). The root watcher tails it and writes the guard on `GET /machines/<mac>/hostname` 200, and also on a repeat PXE more than 60s after assignment.
- **Daemon files take the operator's ownership.** Everything the root watcher creates is chowned to the owner of `http-server/machines/`, so user-run scripts can still write the queue.
- **launchd, not the venv.** Daemons run the watcher and the API with a stable system or Homebrew `python3` (≥3.9; the code avoids 3.10-only syntax). The serving interface is baked into the plist at install because default-route detection fails at boot. dnsmasq is stopped by pid file, never `killall`.
- **Stdlib API, not FastAPI.** The Phase 2 server uses `http.server` so it runs under the same interpreter rules as the watcher with no venv. The hand-written OpenAPI spec is the contract; `test_contract.py` validates real responses and events against it (needs PyYAML + jsonschema in `.venv`, which `just test` prefers).
- **The journal is the only IPC.** The root watcher (`PxeTracker(emit=...)`) and the operator-owned API (install reports) append events to `logs/events.jsonl` under its flock; the API tails it for SSE. No sockets between them. A journal write failure is logged and never blocks assignment, guards or a recorded failure.
- **Entry status comes from disk, events from the journal.** `queued`/`flashed`/`assigned`/`installing`/`installed`/`failed` are derived from `queue.json`, `machine-info.json` and the guard file on every read, so `just reset`/`clean`/`unguard` take effect without events. `failed` is checked first, because a failure removes the guard and a missing guard alone reads as `assigned`. `install-complete` is decided by `completed_at` in `machine-info.json`, stamped before the event is emitted. The watcher completes an entry already assigned to a MAC (crash recovery) instead of consuming a second slot.
- **A failed install reinstalls on its next PXE boot.** A failure (the installer's report, or the timeout) stamps `failed_at`/`failure_reason`/`failure_source` into `machine-info.json` and removes the guard. The next PXE sighting of a failed or `armed` MAC starts a new attempt (`attempt` + 1, `assigned_at` reset, last attempt's markers cleared) before the 60-second repeat-PXE rule is consulted. `just unguard` sets `armed` through `watcher.py --rearm`, so it works however long the reboot takes. An installer failure replaces a timeout failure and then sticks; a timeout failure is cleared by later progress or a hostname fetch. A USB machine has no re-arm, so any progress report after its failure clears it. A repeat PXE past the 60-second window from a machine whose installer never showed any sign of running (no progress report, no hostname-fetch guard) is a failed boot, not a finished install: the watcher emits `install-failed` with source `reboot` and starts a new attempt. Machines assigned before this rule (no `attempt`) keep the old completion rule. The watcher's own `--install-timeout-minutes` defaults to off; `just serve` and the launchd plist pass `INSTALL_TIMEOUT_MINUTES` (45), so a stale plist can't start timing out machines whose reports never arrive. Every change to an existing `machine-info.json` goes through `watcher.update_info` (flock on `info.lock`), because the root watcher and the operator-run API both write it.
- **Installer reports carry no log text.** The WiFi password is embedded in a late-command, and installer logs can echo commands, so a failure reason is a fixed phrase plus at most the crash exception class, further cleaned by the helper and the server. `done` only exempts a machine from the timeout; it does not complete the install. `install-complete` still means the machine PXE-booted again. The API appends report events to the journal itself, so reports work under `just serve-usb`, where no watcher runs.
- **The API runs as the operator.** Its plist carries `UserName`; it needs no root. It binds `0.0.0.0` with no auth (trusted LAN), and the server bind skips `getfqdn()` so startup never stalls on reverse DNS.

## Operator Workflow

```bash
# First-time setup
just setup-wizard       # create config/site.env interactively

# Raspberry Pi provisioning
just download-pi-image  # one-time
just provision          # generate queue (or create Viam machines in full mode)
just flash-batch        # flash all SD cards with swap prompts

# x86 PXE provisioning
just setup              # extract GRUB + kernel from Ubuntu ISO (one-time)
just provision          # create Viam machines + stage credentials (appends to queue)
just serve              # start HTTP + DHCP/TFTP + watcher (Ctrl-C stops all)

# x86 PXE, always-on server (launchd)
just serve-daemon       # once: install dnsmasq + watcher daemons, start HTTP
just provision          # any time while the daemons run
just daemon-status      # daemons, HTTP server, queue
just stop-daemon

# Tests
just test               # unittest discover -s pxe-watcher (uses .venv/bin/python3 when present)

# Provisioner API (runs inside serve / serve-daemon; standalone for debugging)
just api                # foreground on API_PORT (default 8235)
curl -s localhost:8235/api/v1/queue

# x86 USB-stick provisioning (when sharing network with other operators)
just setup              # one-time
just provision          # create Viam machines + stage credentials
just flash-usb-batch    # pick server interface, then plug-in/wipe/write each stick
just serve-usb          # HTTP only, no DHCP/TFTP
```

## Target Machine Config

All configurable via `config/site.env`:
- User/password (default: viam/checkmate)
- Timezone (default: America/New_York)
- WiFi SSID + password (optional)
- SSH authorized key
- Headless (`multi-user.target`)
- Console font: Terminus 16x32
- Packages: from `config/environments/<env>.packages.txt` (seeded from `config/packages.txt.example`; per-env, gitignored)
- Viam CLI + viam-agent (full/agent mode)
- Tailscale auto-join (if auth key provided)
