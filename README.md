# Viam Batch Provisioner

Low-touch provisioning for x86 Linux machines (PXE) and Raspberry Pis (SD card). Installs Ubuntu or Raspberry Pi OS, configures user accounts, SSH, WiFi, and optionally deploys [Viam](https://viam.com) agent + credentials and [Tailscale](https://tailscale.com) VPN.

## What it does

Boots a target machine over the network (x86) or from a pre-flashed SD card (Pi) and runs an unattended install. The result is a host with an OS, hostname, user account, SSH, WiFi, and — in `full` or `agent` mode — viam-agent and a Tailscale membership.

**x86 machines** (Meerkats, NUCs, Minisforum, etc.) install over the network. Two modes:
- **PXE** — the target's UEFI ROM does network boot; the host runs a proxy DHCP + TFTP server. Use when one operator has the network to themselves.
- **USB** — flash a per-machine boot stick whose GRUB config points at a fixed server IP. Use when multiple operators share a network, or when the LAN's DHCP server won't tolerate a proxy.

**Raspberry Pis** boot from SD cards flashed on the workstation.

## Provision modes

| Mode | What gets installed |
|------|---------------------|
| `full` | OS + Viam agent with cloud credentials + Tailscale |
| `agent` | OS + Viam agent binary (user adds credentials themselves) |
| `os-only` | Just the OS with user account, SSH, and WiFi |

## Prerequisites

- macOS or Linux workstation
- Docker with the `compose` plugin (Docker Desktop, or a CLI engine such as Colima or OrbStack)
- Python 3
- `just` — command runner (`brew install just`)
- `dnsmasq` — for PXE boot (`brew install dnsmasq`)
- `p7zip` — for ISO extraction (`brew install p7zip`)

For Viam `full` mode:
- Viam CLI (`brew install viam`)

Run `just doctor` at any time to verify all of the above are installed. The
setup wizard runs the same check before prompting, and creates the Python
venv with `viam-sdk` for you when you choose `full` mode.

## Quick start

```bash
# 1. Clone
git clone https://github.com/ashitaka1/viam-batch-provisioner.git
cd viam-batch-provisioner

# 2. Interactive setup — creates your environment config
just setup-wizard

# 3. One-time setup (PXE only — extracts boot files from Ubuntu ISO)
just setup
```

### Provisioning Raspberry Pis

```bash
just download-pi-image
just provision my-pi 10
just flash-batch
# Insert cards, power on. ~5 minutes per Pi.
```

### Provisioning x86 machines (PXE)

```bash
just provision my-machine 6
just serve
# Power on machines with F12/network boot. ~15 minutes per machine.
# Ctrl-C stops all services.
```

For a Mac that stays on as the lab's provisioning server, install the
services as launchd daemons instead. They survive reboots, and `just
provision` adds machines to the queue while they run:

```bash
just serve-daemon         # once: picks the interface, installs the daemons
just provision my-machine 6   # any time; appends to the queue
just daemon-status
just stop-daemon          # removes the daemons
```

`just serve`, `just serve-usb` and `just serve-daemon` also start the [provisioner API](#provisioner-api)
on `API_PORT` (default 8235), advertised over Bonjour as `_viam-provisioner._tcp`.

The HTTP server runs in Docker with a restart policy, so it returns after a
reboot once the Docker engine is up: set Docker Desktop to start at sign-in,
or `brew services start colima` for a CLI install. Keep the repo outside
`~/Desktop`, `~/Documents` and `~/Downloads` (root daemons cannot read those
without a TCC grant).

### Provisioning x86 machines (USB sticks)

Each stick's GRUB config carries the host's server IP and the target's
hostname on the kernel cmdline, so two operators on the same subnet can
provision in parallel without colliding.

```bash
just provision my-machine 6     # generate queue (or create Viam machines in full mode)
just flash-usb-batch            # pick interface, then plug in / wipe / write each stick
just serve-usb                  # HTTP server for ISO + credentials
# Boot each target from its stick (UEFI USB boot). ~15 minutes per machine.
```

`flash-usb-batch` picks a server interface up front (default-route wired
interface preferred), confirms with the operator, then walks the queue one
machine at a time: prompts you to plug in a stick, auto-detects the new
device, shows what will be wiped, asks for `yes`, writes the stick, and
labels it on disk.

## One-time BIOS setup (x86 only)

Each x86 machine model needs a one-time BIOS configuration with a monitor attached:

1. **Enable PXE/Network Boot** — look for "UEFI PXE" or "Network Stack"
2. **Set Network as first boot option** (temporary — the installer resets this to disk-first)
3. **Set "Restore on AC Power Loss" to Power On** — so machines boot when plugged in
4. **Disable Secure Boot** — if the machine rejects the GRUB bootloader

The exact menu locations vary by vendor.

## How it works

### PXE boot chain (x86)

```
Power on → UEFI PXE ROM → DHCP (dnsmasq proxy) → TFTP (GRUB) →
Ubuntu kernel + initrd → ISO download over HTTP → Ubuntu autoinstall →
late-commands fetch hostname + credentials → first boot with all services
```

### USB boot chain (x86)

```
Power on → UEFI USB boot → GRUB on the stick → kernel + initrd from the stick →
ISO download over HTTP (server IP baked into grub.cfg) → Ubuntu autoinstall →
late-commands read viam_hostname=<name> from /proc/cmdline →
fetch credentials from /machines/by-name/<name>/ → first boot
```

The only LAN service is the HTTP server. The target reaches it at the
IP baked into its own grub.cfg.

### SD card flow (Pi)

```
flash-pi-sd.sh → write OS image → mount boot partition (FAT32) →
write cloud-init user-data + network config → first boot runs
Phase 2 service for packages + Viam + Tailscale
```

### Components

| Component | Role |
|-----------|------|
| **dnsmasq** (native) | Proxy DHCP for PXE discovery + TFTP for GRUB/kernel/initrd |
| **nginx** (Docker) | HTTP server for Ubuntu ISO, autoinstall configs, credentials |
| **pxe-watcher** | Sniffs DHCP for PXE clients, assigns hostnames by arrival order, writes GRUB guards (on hostname fetch or repeat PXE), appends lifecycle events to `logs/events.jsonl` |
| **queue_store.py** | Sole writer of `queue.json`: locked, atomic append/assign used by the watcher, the API and scripts |
| **provisioner_api.py** | REST + SSE server (stdlib) implementing `openapi/provisioner.yaml`; runs as the operator on port 8235 |
| **daemon.sh** | Installs dnsmasq, watcher, API and Bonjour as launchd daemons (`just serve-daemon`) |
| **provision-batch.sh** | Creates Viam machines + retrieves credentials (full mode); appends to the queue |
| **flash-pi-sd.sh** | Writes Pi OS to SD card with cloud-init config |
| **setup-wizard.sh** | Interactive environment configuration |

### Security model

- **Provisioning API key** stays on the operator's workstation — never deployed to targets
- Per-machine Viam credentials are fetched via the Python SDK and staged temporarily
- Tailscale auth key is served over the local network during install, deleted after first use
- SSH public key is baked into the OS config
- All secrets live in `config/` (gitignored)
- The provisioner API has no authentication and listens on every interface. It accepts per-machine credentials in request bodies in cleartext, so it belongs on a trusted lab network only.

## Provisioner API

The contract is `openapi/provisioner.yaml`. The server listens on `API_PORT`
(default 8235) and advertises itself over Bonjour as `_viam-provisioner._tcp`
with `api=v1` in the TXT record.

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/provision` | Queue machines: `[{"name": "lab-7", "credentials": {viam.json}}]`. Credentials are optional. Per-item result is `added` or `skipped`. |
| `GET` | `/api/v1/queue` | Every entry with its derived status, plus `last_event_id` |
| `GET` | `/api/v1/queue/{name}` | One entry |
| `DELETE` | `/api/v1/queue/{name}` | Remove an unassigned entry and its staged credentials (409 once assigned) |
| `GET` | `/api/v1/status` | Service health (nginx, dnsmasq, watcher), queue counts, server address |
| `GET` | `/api/v1/events` | Server-Sent Events; send `Last-Event-ID` to replay |

Entry status is derived from disk on every read: `queued`, `flashed` (USB),
`assigned` (PXE client bound), `installing` (installer fetched its hostname),
`installed` (rebooted from disk after install). Events are `machine-assigned`,
`install-started`, `guard-installed` and `install-complete`; a `resync` event
tells a client its cursor can no longer be served.

```bash
curl -s localhost:8235/api/v1/queue | jq
curl -N -H 'Last-Event-ID: 0' localhost:8235/api/v1/events
dns-sd -B _viam-provisioner._tcp
```

`just test` validates the server's responses and events against the spec when
PyYAML and jsonschema are importable: `.venv/bin/pip install pyyaml jsonschema`.

## Environment configuration

All site-specific settings live in `config/site.env` (created by `just setup-wizard`). Multiple environments can be stored in `config/environments/` and switched between.

The environment holds stable settings (credentials, WiFi, SSH key, timezone). Per-run details (hostname prefix, count) are passed as arguments to `just provision`.

`just provision` appends: it adds `<count>` machines after the highest existing `<prefix>-N` in the queue and skips names already queued, so running it again extends the batch. Use `just clean` to start a new batch from scratch.

For PXE, dnsmasq answers proxy DHCP on the subnet of the serving interface. Set `PXE_PROXY_SUBNET` (CIDR, e.g. `10.1.0.0/20`) in `site.env` when the provisioning network differs from that interface's own subnet.

Set `API_PORT` in `site.env` to move the provisioner API off 8235.

## Commands

| Command | Description |
|---------|-------------|
| `just doctor` | Verify host tools (dnsmasq, p7zip, docker, viam CLI) |
| `just setup-wizard` | Interactive setup — create/switch environments |
| `just provision <prefix> <count>` | Add `<count>` machines to the queue (creates them in Viam in full mode) |
| `just serve` | Start all PXE services, watcher and API (Ctrl-C stops all) |
| `just serve-daemon` | Install dnsmasq, watcher, API and Bonjour as launchd daemons; start HTTP server |
| `just stop-daemon` | Remove the daemons and stop the HTTP server |
| `just daemon-status` | Daemon, HTTP server and queue state |
| `just logs` | Follow HTTP requests |
| `just serve-usb` | Start HTTP server and API, no DHCP/TFTP (for USB-mode targets) |
| `just flash <device> <name>` | Flash a single Pi SD card |
| `just flash-batch` | Flash all queued Pi SD cards with swap prompts |
| `just flash-usb <device> <name>` | Flash a single x86 USB boot stick |
| `just flash-usb-batch` | Flash one USB stick per queued x86 machine |
| `just download-pi-image` | Download Raspberry Pi OS Lite |
| `just setup` | Extract GRUB + kernel from Ubuntu ISO (one-time) |
| `just status` | Show queue state + service status |
| `just clean` | Wipe the queue and all provisioning state |
| `just reset` | Re-use current queue (mark unassigned, clear MAC assignments and PXE guards) |
| `just stop` | Stop all PXE services |
| `just unguard <name-or-mac>` | Clear one machine's PXE guard and completion mark so it can re-attempt install |
| `just api` | Run the provisioner API alone in the foreground |
| `just test` | Run the unit tests (prefers `.venv/bin/python3` for the contract test) |

## Target machine config

Configurable via `config/site.env`:

- Username + password (default: `viam` / `checkmate`)
- SSH authorized key
- WiFi SSID + password (optional)
- Timezone (default: `America/New_York`)
- Console font: Terminus 16x32 for readability

Installed automatically:
- apt packages from `config/environments/<env>.packages.txt` (per-env list, seeded from `config/packages.txt.example` on first use; edit before `just provision` to customize)
- Viam CLI + viam-agent (full/agent mode)
- Tailscale (if auth key provided)

## Tested hardware

| Machine | Architecture | Status |
|---------|-------------|--------|
| System76 Meerkat (CRARL579) | Intel, dual I226-V NICs | Fully validated |
| Minisforum UM890 Pro | AMD Ryzen, dual Realtek 2.5GbE | Fully validated |
| Advantech MIC-770 V3 | Intel Core i-series, dual Intel NICs (I219 + I210) | Fully validated |
| Raspberry Pi 5 | ARM64 | Fully validated |
| Raspberry Pi 4 | ARM64 | Untested (should work) |

## License

Internal tool — not publicly licensed.
