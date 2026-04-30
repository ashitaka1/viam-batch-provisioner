# Viam Batch Provisioner

Low-touch provisioning for x86 Linux machines (PXE) and Raspberry Pis (SD card). Installs Ubuntu or Raspberry Pi OS, configures user accounts, SSH, WiFi, and optionally deploys [Viam](https://viam.com) agent + credentials and [Tailscale](https://tailscale.com) VPN.

## What it does

Plug in a machine, power it on, network-boot or boot from a pre-flashed USB stick, and walk away. It gets an OS, a hostname, SSH access, and (optionally) connects to Viam cloud and your Tailscale network. No interactive installers, no manual configuration on the target.

**x86 machines** (Meerkats, NUCs, Minisforum, etc.) install over the network. Two modes:
- **PXE** — the target's UEFI ROM does network boot; the host runs a proxy DHCP + TFTP server. Best when one operator has the network to themselves.
- **USB** — flash a per-machine boot stick whose GRUB config points at a fixed server IP. No DHCP/TFTP needed. Use this when multiple operators share a network or when the LAN's DHCP doesn't allow a proxy.

**Raspberry Pis** use SD card flashing — you flash cards from your workstation and insert them.

## Provision modes

| Mode | What gets installed |
|------|---------------------|
| `full` | OS + Viam agent with cloud credentials + Tailscale |
| `agent` | OS + Viam agent binary (user adds credentials themselves) |
| `os-only` | Just the OS with user account, SSH, and WiFi |

## Prerequisites

- macOS or Linux workstation
- Docker Desktop
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
# Insert cards, power on. Done in ~5 minutes per Pi.
```

### Provisioning x86 machines (PXE)

```bash
just provision my-machine 6
just serve
# Power on machines with F12/network boot. Done in ~15 minutes each.
# Ctrl-C stops all services when finished.
```

### Provisioning x86 machines (USB sticks)

Use this when more than one person on the same network is provisioning at
once, or when the LAN's DHCP server won't tolerate a proxy. Each stick is
unique — its GRUB config has the host's IP and the target's hostname baked
in, so two operators on the same subnet don't step on each other.

```bash
just provision my-machine 6     # generate queue (or create Viam machines in full mode)
just flash-usb-batch            # pick interface, then plug in / wipe / write each stick
just serve-usb                  # HTTP only — no DHCP, no TFTP, no watcher
# Boot each target from its stick (UEFI USB boot). Done in ~15 min/machine.
```

The batch flasher picks the best server interface up front (default-route
wired interface preferred), shows you the candidates, and asks you to
confirm. It then walks one machine at a time: prompts you to plug in,
auto-detects the new device, shows what'll be wiped, asks for `yes`, then
writes the stick and labels it on disk.

## One-time BIOS setup (x86 only)

Each x86 machine model needs a one-time BIOS configuration with a monitor attached:

1. **Enable PXE/Network Boot** — look for "UEFI PXE" or "Network Stack"
2. **Set Network as first boot option** (temporary — the installer resets this to disk-first)
3. **Set "Restore on AC Power Loss" to Power On** — so machines boot when plugged in
4. **Disable Secure Boot** — if the machine rejects the GRUB bootloader

The exact menu locations vary by vendor. Once done, all subsequent provisioning is hands-free.

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

No DHCP proxy, no TFTP, no DHCP-watcher. The only LAN service is the
HTTP server, which only the booted target talks to (and only at the IP
baked into its own stick).

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
| **pxe-watcher** | Sniffs DHCP for PXE clients, assigns hostnames by arrival order |
| **provision-batch.sh** | Creates Viam machines + retrieves credentials (full mode) |
| **flash-pi-sd.sh** | Writes Pi OS to SD card with cloud-init config |
| **setup-wizard.sh** | Interactive environment configuration |

### Security model

- **Provisioning API key** stays on the operator's workstation — never deployed to targets
- Per-machine Viam credentials are fetched via the Python SDK and staged temporarily
- Tailscale auth key is served over the local network during install, deleted after first use
- SSH public key is baked into the OS config
- All secrets live in `config/` (gitignored)

## Environment configuration

All site-specific settings live in `config/site.env` (created by `just setup-wizard`). Multiple environments can be stored in `config/environments/` and switched between.

The environment holds stable settings (credentials, WiFi, SSH key, timezone). Per-run details (hostname prefix, count) are passed as arguments to `just provision`.

## Commands

| Command | Description |
|---------|-------------|
| `just doctor` | Verify host tools (dnsmasq, p7zip, docker, viam CLI) |
| `just setup-wizard` | Interactive setup — create/switch environments |
| `just provision <prefix> <count>` | Generate queue or create Viam machines |
| `just serve` | Start all PXE services + watcher (Ctrl-C stops all) |
| `just serve-usb` | Start HTTP server only (for USB-mode targets) |
| `just flash <device> <name>` | Flash a single Pi SD card |
| `just flash-batch` | Flash all queued Pi SD cards with swap prompts |
| `just flash-usb <device> <name>` | Flash a single x86 USB boot stick |
| `just flash-usb-batch` | Flash one USB stick per queued x86 machine |
| `just download-pi-image` | Download Raspberry Pi OS Lite |
| `just setup` | Extract GRUB + kernel from Ubuntu ISO (one-time) |
| `just status` | Show queue state + service status |
| `just clean` | Wipe all provisioning state |
| `just reset` | Re-use current queue (mark unassigned) |
| `just stop` | Stop all PXE services |

## Target machine config

Configurable via `config/site.env`:

- Username + password (default: `viam` / `checkmate`)
- SSH authorized key
- WiFi SSID + password (optional)
- Timezone (default: `America/New_York`)
- Console font: Terminus 16x32 for readability

Installed automatically:
- openssh-server, avahi-daemon, curl, jq, net-tools, NetworkManager, mosh, speedtest-cli, unattended-upgrades
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
