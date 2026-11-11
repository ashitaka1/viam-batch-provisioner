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
- Viam CLI (`brew install viam`), for the bash tooling. The macOS app doesn't use it.

The macOS app signs in to Viam with API keys it keeps in the login keychain. Create a key for an organization or a location at app.viam.com (or with `viam organizations api-key create` / `viam locations api-key create`), then click **Add Viam API Key…**, paste its ID and key, and choose **Organization** or **Location** to match the key. The app checks the key with Viam and works out which organization or location it reaches; when the key reaches several, it asks for the ID. A key that fails is not stored. The app acts with each key's access alone, and holds any number of keys: an environment uses the key that covers its location, preferring a location key, and an environment no key covers reads "Not reachable with this key" in the sidebar, with Provision disabled. **Settings → API Keys** lists the keys by what they reach (`Acme · organization`, `Shop floor · Acme`) with each key ID's first 8 characters; **Remove** deletes the key from this Mac only, and it stays valid at Viam. With no keys left the app is signed out. The app talks to `https://app.viam.com`; `defaults write com.bringingfire.viam-provisioner ViamBaseURL <url>` points it elsewhere.

The app provisions into a running server. Choose the server from the toolbar: servers on the network appear by name (allow Local Network access when macOS asks), and **Connect to Address…** takes a host and the API port (8235). Select an environment and click **Provision…** to queue a batch: in full mode the app creates each machine in Viam and sends its credentials; agent and OS-only batches send names only. **Queue** shows each machine live, from waiting through installed or failed, with its MAC, times and failure reason. Each install that completes or fails posts a notification (allow notifications when macOS asks); a later outcome for the same machine replaces the earlier one. Against the Swift server it shows the machine's provisioning steps (Found, Booting, Downloading the OS with a percentage, Installing, Configuring, Installed, which reads "Installed · restarting" for a full-mode machine until Viam reports it online, then Viam online), and a failure names its step; against the Python server it shows the install stage. **History** lists the batches provisioned from this Mac. The Python server installs from `config/site.env`, not from the environment's account, network and package settings.

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

To flash one card: `just flash /dev/disk4 my-pi-1`.

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
labels it on disk. To flash one stick: `just flash-usb /dev/disk5 my-machine-1`.

## After provisioning

- **SSH**: `ssh <name>`, through the `~/.ssh/config` Host block the setup wizard offers to add
- **Viam**: machines appear at app.viam.com (`full` mode)
- **Tailscale**: machines join your tailnet (if an auth key is configured)

## One-time BIOS setup (x86 only)

Each x86 machine model needs a one-time BIOS configuration with a monitor attached:

1. **Enable PXE/Network Boot** — look for "UEFI PXE" or "Network Stack"
2. **Set the boot order to disk, USB, then network** — a blank disk falls through to a USB stick or PXE, and an installed machine boots its disk
3. **Set "Restore on AC Power Loss" to Power On** — so machines boot when plugged in

A machine that already has an OS on its disk needs one network boot: the boot-menu key at power-on, or `sudo efibootmgr --bootnext <PXE entry>` from its running OS.
4. **Disable Secure Boot** — if the machine rejects the GRUB bootloader

Keys, menu paths and quirks for each tested model are in [docs/hardware.md](docs/hardware.md).

## How it works

### PXE boot chain (x86)

```
Power on → UEFI PXE ROM → DHCP (dnsmasq proxy) → TFTP (GRUB) →
Ubuntu HWE kernel + initrd → ISO download over HTTP → Ubuntu autoinstall →
late-commands fetch hostname + credentials → first boot with all services
```

### USB boot chain (x86)

```
Power on → UEFI USB boot → GRUB on the stick → HWE kernel + initrd from the stick →
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
network-setup service for packages + Viam + Tailscale
```

Components, data layout and invariants are in [ARCHITECTURE.md](ARCHITECTURE.md).

### Security model

- **Provisioning API key** stays on the operator's workstation — never deployed to targets
- Per-machine Viam credentials are fetched via the Python SDK and staged temporarily
- Tailscale auth key is served over the local network during install, deleted after first use
- SSH public key is baked into the OS config
- All secrets live in `config/` (gitignored)
- The provisioner API has no authentication and listens on every interface. It accepts per-machine credentials in request bodies in cleartext, so it belongs on a trusted lab network only.
- Anyone who can reach the file server can submit an install report. The worst a forged report does is mark a machine that is still installing as failed, so it reinstalls on its next PXE boot. Machines that have completed are not affected.

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
| `POST` | `/api/v1/install-reports` | Progress or failure report from a target's installer. The file server on `HTTP_PORT` forwards exactly this path, so targets never talk to the API port. |

Entry status is derived from disk on every read: `queued`, `flashed` (USB),
`assigned` (PXE client bound), `installing` (installer fetched its hostname),
`installed` (the installer reported `done`), `failed`. Events are
`machine-assigned`, `install-started`, `install-progress`, `install-failed`,
`guard-installed` and `install-complete`; a `resync` event tells a client its
cursor can no longer be served.

### Failed installs

The installer reports each stage it enters (`late-commands`, `identity`,
`tooling`, `tailscale`, `done`) and, from autoinstall's `error-commands` when
autoinstall runs them, a failure. A failure marks the machine `failed` and
removes its PXE guard, so rebooting it over the network installs again. If the
machine's boot order puts the disk first, use the one-time boot menu to PXE. A
USB-flashed machine has no PXE boot to restart it, so a progress report after
its failure means the stick was booted again and clears the failure. `just
status` does not show failures; read them from the API.

A boot that never reaches the installer, for example because Secure Boot
rejected GRUB and the machine fell through to its old disk, is caught when you
network-boot the machine again: the server records the failure and starts a
fresh install instead of treating the reboot as a finished one.

An install that goes silent is failed by the server after
`INSTALL_TIMEOUT_MINUTES` (default 45, `0` turns it off). Any report counts as
a sign of life. The final `done` report marks a PXE machine `installed`,
whichever device its firmware boots next; a USB-flashed machine stays
`flashed`. Reports never include installer log text, since logs can echo
commands that contain secrets. `just unguard <name>` makes the machine's next
PXE boot start a new install, however long from now it happens, without
marking it failed.

After upgrading, run `just serve-daemon` (or restart `just serve`) so nginx is
recreated with the report forwarding and the watcher is started with the
timeout setting. Start the HTTP server with `just up` rather than a bare
`docker compose up`: compose does not read `site.env`, so only the recipes pass
a custom `API_PORT` through to nginx.

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

### Robot network

Each x86 machine gets a static address on its robot-network port: `192.168.20.1/24` on the first `enp*` port other than the one cabled at install. Two settings in `site.env`, also asked by `just setup-wizard` and kept per environment in the app, change that:

- `ROBOT_NET_ADDRESS`: the address with its prefix, or `none` for no robot network. Only private addresses (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) are accepted; `build-config.sh` refuses anything else.
- `ROBOT_NET_PORT`: the interface that carries it, such as `enp3s0`. [`docs/hardware.md`](docs/hardware.md) lists each model's. The named port gets the address and every other wired port DHCP, so the installed machine comes online on whichever of them is cabled. A machine without that port fails its install before partitioning with `No port <port>`. A machine installed through the named port finishes, offline: its `done` report carries the warning `Cabled on the robot-network port <port>: move the cable to another port.`, which the queue entry and the app show. Moving the cable brings it online without a reboot.

Set `API_PORT` in `site.env` to move the provisioner API off 8235. Set `INSTALL_TIMEOUT_MINUTES` to change how long an install may go without any sign of life before it is marked failed (default 45, `0` turns it off).

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
| `just unguard <name-or-mac>` | Make one machine reinstall on its next PXE boot, however long from now |
| `just api` | Run the provisioner API alone in the foreground |
| `just app` | Build, sign and open the macOS app |
| `just import-env <env>` | Copy `config/environments/<env>.env` into the macOS app's environments |
| `just test` | Run the unit tests (prefers `.venv/bin/python3` for the contract test) |

## Target machine config

Configurable via `config/site.env`:

- Username + password (default: `viam` / `checkmate`)
- SSH authorized key
- WiFi SSID + password (optional)
- Timezone (default: `America/New_York`)
- Robot network address and port (see [Robot network](#robot-network))
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
| ASUS NUC (BIOS GDPTL579) | Intel, dual I226-V NICs | Fully validated |
| AAEON CEXD-INTRBL | Intel Core Ultra (Panther Lake), four I226-V NICs | Installs over PXE; port choice and a second disk are open ([#128](https://github.com/ashitaka1/viam-batch-provisioner/issues/128)) |
| Raspberry Pi 5 | ARM64 | Fully validated |
| Raspberry Pi 4 | ARM64 | Untested (should work) |

BIOS preparation for each x86 model: [docs/hardware.md](docs/hardware.md).

## Known issues

- Intel BE200 WiFi (device 7740) on newer Meerkats has no firmware in Ubuntu 24.04, so WiFi doesn't come up ([#3](https://github.com/ashitaka1/viam-batch-provisioner/issues/3)).
- The Minisforum UM890 Pro's BIOS ignores the boot order the installer sets; set NVMe above Network in its Fixed Boot Order by hand ([#4](https://github.com/ashitaka1/viam-batch-provisioner/issues/4)).
- The AAEON CEXD-INTRBL's BIOS also puts PXE back ahead of the disk, and its PXE ROM can take minutes to fetch GRUB. Set NVMe first and install through Save & Exit → Boot Override; a blank disk falls through to the network on its own ([#128](https://github.com/ashitaka1/viam-batch-provisioner/issues/128)).

Open issues: https://github.com/ashitaka1/viam-batch-provisioner/issues

## License

Internal tool — not publicly licensed.
