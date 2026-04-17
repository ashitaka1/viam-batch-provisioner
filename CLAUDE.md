# Viam Batch Provisioner

Zero-touch provisioning for x86 Linux machines (PXE) and Raspberry Pis (SD card) as Viam robotics hosts.

A Flutter desktop GUI (macOS only, under `app/`) coexists with the CLI — see `APP_SPEC.md`.

## Configuration

All site-specific settings live in `config/site.env` (gitignored). Run `just setup-wizard` to create it interactively. Settings include: machine prefix/count, username/password, WiFi, SSH key, Viam Cloud credentials (optional), Tailscale (optional).

Three provision modes:
- **full** — creates machines in Viam, installs viam-agent, deploys credentials
- **agent** — installs viam-agent binary, user adds credentials themselves
- **os-only** — just configures the OS, no Viam software

## Architecture

### x86 PXE Boot Chain

UEFI PXE ROM → dnsmasq (proxy DHCP + TFTP) → GRUB → Ubuntu kernel + initrd via TFTP → installer downloads ISO via HTTP → Ubuntu autoinstall → late-commands fetch identity + credentials → first boot with viam-agent + Tailscale

### Raspberry Pi SD Card

`flash-pi-sd.sh` writes OS image → mounts FAT32 boot partition → writes cloud-init user-data, network-config, meta-data → first boot runs Phase 2 service for network-dependent setup (packages, viam-agent, Tailscale)

### Components

- **dnsmasq** (native, not Docker) — proxy DHCP + TFTP for PXE boot
- **nginx** (Docker) — HTTP server for ISO, autoinstall configs, credentials
- **pxe-watcher** (host script) — assigns names to MACs as machines PXE boot
- **provision-batch.sh** — creates Viam machines + fetches credentials (full mode), or generates names-only queue (os-only/agent mode)
- **flash-pi-sd.sh** / **flash-batch.sh** — SD card flashing for Pis
- **build-config.sh** — generates PXE autoinstall user-data from template
- **setup-wizard.sh** — interactive config creation

### Key Design Decisions

- **GRUB, not netboot.xyz/iPXE.** GRUB handles network boot directly from the Ubuntu ISO's signed binary.
- **dnsmasq runs natively.** Docker Desktop for Mac can't do host networking for broadcast DHCP/TFTP.
- **NIC names discovered at install time.** Dynamic detection, no hardcoded interface names.
- **Provisioning key pattern.** Org-scoped API key fetches per-machine cloud credentials via Python SDK. The org key never touches target machines.
- **Pi OS uses cloud-init.** Pi OS Trixie has native cloud-init on the boot partition (FAT32, mountable from macOS). Two-phase boot: offline config first, network-dependent setup via systemd service.
- **Boot order reset after PXE install.** `efibootmgr` moves disk above network boot.

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
just build-config       # generate autoinstall config
just up && just dhcp    # start HTTP server + DHCP/TFTP
just provision          # create Viam machines + stage credentials
just watch              # start PXE watcher
```

## Target Machine Config

All configurable via `config/site.env`:
- User/password (default: viam/checkmate)
- Timezone (default: America/New_York)
- WiFi SSID + password (optional)
- SSH authorized key
- Headless (`multi-user.target`)
- Console font: Terminus 16x32
- Packages: openssh-server, curl, jq, net-tools, NetworkManager, unattended-upgrades, mosh, speedtest-cli
- Viam CLI + viam-agent (full/agent mode)
- Tailscale auto-join (if auth key provided)
