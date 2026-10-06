# Quick Start

## Prerequisites

- macOS or Linux
- Docker with the `compose` plugin (Docker Desktop, Colima, OrbStack, or Docker Engine)
- Python 3
- `just` (`brew install just`)
- `p7zip` (`brew install p7zip`) — for PXE server setup only
- `dnsmasq` (`brew install dnsmasq`) — for PXE server setup only

Run `just doctor` to verify everything's installed.

## Setup

```bash
git clone <repo-url> && cd viam-batch-provisioner

# Interactive setup — creates config/site.env with all your settings.
# The wizard runs the prereq check and (in full mode) sets up the
# Python venv with viam-sdk for you.
just setup-wizard
```

The wizard walks you through: machine naming, user/password, WiFi, SSH keys,
Viam Cloud integration (optional), and Tailscale (optional).

## Provisioning Raspberry Pis

```bash
# 1. Download Pi OS image (one-time)
just download-pi-image

# 2. Generate the machine queue
just provision hackathon-pi 10

# 3. Flash all SD cards (prompts for card swaps)
just flash-batch

# 4. Insert cards, power on. First boot configures everything automatically.
```

To flash a single card:
```bash
just flash /dev/disk4 lab-pi-1
```

## Provisioning x86 Machines (PXE)

```bash
# 1. Extract GRUB + kernel from Ubuntu ISO (one-time)
just setup

# 2. Generate queue + credentials
just provision lab-meerkat 6

# 3. Start all PXE services + watcher (Ctrl-C stops everything)
just serve
#    …or install them as always-on launchd daemons:
# just serve-daemon

# 4. Power on machines (F12 for network boot)
```

`just provision` appends to the queue, so you can add machines while the
server runs. `just clean` wipes it.

Either way the REST/SSE API is up on port 8235 (Bonjour `_viam-provisioner._tcp`):
`curl localhost:8235/api/v1/queue`.

If an install fails, or goes 45 minutes without any sign of life, the machine
shows as `failed` in the API (`curl localhost:8235/api/v1/queue`); `just status`
does not show it. Reboot it over the network to
install again; if its boot order puts the disk first, use the one-time boot
menu to PXE. `just unguard <name>` does the same for a machine that installed
but needs reinstalling.

## Provisioning x86 Machines (USB sticks)

Use this when multiple people share the network, or when you can't run
PXE/DHCP on the LAN. Each stick has a fixed server IP and the target's
hostname baked into its bootloader, so two operators don't conflict.

```bash
# 1. Extract GRUB + kernel from Ubuntu ISO (one-time)
just setup

# 2. Generate queue + credentials
just provision lab-meerkat 6

# 3. Flash one USB stick per machine (interactive — picks interface,
#    walks you through plug-in / wipe / write for each stick)
just flash-usb-batch

# 4. HTTP-only server (no DHCP/TFTP). Ctrl-C to stop.
just serve-usb

# 5. Boot each target from its stick (UEFI USB boot)
```

To flash a single stick (e.g., for testing):
```bash
just flash-usb /dev/disk5 lab-meerkat-1
```

## Provision Modes

Set in `config/site.env` (or via the setup wizard):

| Mode | What happens |
|------|-------------|
| `full` | Creates machines in Viam, installs viam-agent + credentials |
| `agent` | Installs viam-agent binary (user adds credentials themselves) |
| `os-only` | Just configures the OS — no Viam software at all |

## After Provisioning

- **SSH**: `ssh <prefix>-<name>` (if you used the setup wizard's SSH config)
- **Viam**: machines appear at app.viam.com (full mode only)
- **Tailscale**: machines join your tailnet (if configured)

## Commands

| Command | Description |
|---------|-------------|
| `just doctor` | Verify host tools are installed |
| `just setup-wizard` | Interactive setup — creates config/site.env |
| `just provision <prefix> <count>` | Generate queue or create Viam machines |
| `just serve` | Start all PXE services + watcher (Ctrl-C stops everything) |
| `just serve-daemon` | Install PXE services as always-on launchd daemons |
| `just stop-daemon` | Remove the daemons |
| `just daemon-status` | Daemon, HTTP server and queue state |
| `just serve-usb` | HTTP-only server for USB-flashed targets |
| `just stop` | Stop all PXE services |
| `just flash-batch` | Flash all queued Pi SD cards |
| `just flash <dev> <name>` | Flash a single Pi SD card |
| `just flash-usb-batch` | Flash one x86 USB boot stick per queued machine |
| `just flash-usb <dev> <name>` | Flash a single x86 USB boot stick |
| `just download-pi-image` | Download Raspberry Pi OS Lite |
| `just setup` | Extract GRUB + kernel from Ubuntu ISO (one-time) |
| `just status` | Show queue state + service status |
| `just reset` | Re-use current queue (mark unassigned) |
| `just clean` | Wipe all provisioning state |

Debugging helpers (run individual services for iteration): `just up`, `just down`, `just dhcp`, `just watch`, `just build-config`.
