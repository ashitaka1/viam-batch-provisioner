# Viam Batch Provisioner

Zero-touch provisioning for x86 Linux machines (PXE or USB stick) and Raspberry Pis (SD card) as Viam robotics hosts.

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
- **nginx** (Docker) — HTTP server for ISO, autoinstall configs, credentials
- **pxe-watcher** (host script) — assigns names to MACs as machines PXE boot
- **provision-batch.sh** — creates Viam machines + fetches credentials (full mode), or generates names-only queue (os-only/agent mode)
- **flash-pi-sd.sh** / **flash-batch.sh** — SD card flashing for Pis
- **flash-usb.sh** / **flash-usb-batch.sh** — x86 USB boot stick flashing (per-machine, fixed server)
- **pick-server-iface.sh** — scores host network interfaces; used by USB flash + serve-usb
- **build-config.sh** — generates PXE autoinstall user-data from template
- **setup-wizard.sh** — interactive config creation

### Key Design Decisions

- **GRUB, not netboot.xyz/iPXE.** GRUB handles network boot directly from the Ubuntu ISO's signed binary.
- **dnsmasq runs natively.** Docker Desktop for Mac can't do host networking for broadcast DHCP/TFTP.
- **NIC names discovered at install time.** Dynamic detection, no hardcoded interface names.
- **Provisioning key pattern.** Org-scoped API key fetches per-machine cloud credentials via Python SDK. The org key never touches target machines.
- **Pi OS uses cloud-init.** Pi OS Trixie has native cloud-init on the boot partition (FAT32, mountable from macOS). Two-phase boot: offline config first, network-dependent setup via systemd service.
- **Boot order reset after PXE install.** `efibootmgr` moves disk above network boot.
- **USB mode bakes identity into the bootloader.** Each stick's `grub.cfg` carries the host's `IP:port` and `viam_hostname=<name>` on the kernel cmdline, so the installer doesn't need a DHCP-watcher to learn its identity. Credentials are pre-staged at `/machines/by-name/<name>/viam.json` at flash time. The `user-data.tpl` late-commands try the cmdline first and fall back to MAC lookup, so the same template serves both modes.
- **USB layout: single FAT32 ESP, GPT.** GRUB is installed at `/EFI/BOOT/BOOTX64.EFI` (UEFI fallback path) so the stick boots on any UEFI firmware without per-machine boot entries.
- **Best-interface picker.** `pick-server-iface.sh` enumerates UP IPv4 interfaces, prefers the default-route one, then wired (`en*`/`eth*`/`enp*`) over wireless. Operator confirms the choice once per batch.
- **Server address persisted between flash and serve.** `flash-usb-batch.sh` writes the chosen `IP:port` to `config/.server-address` (gitignored). `just serve-usb` reads it so `build-config.sh` stamps the same address into `user-data` that's baked into the sticks.

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
just provision          # create Viam machines + stage credentials
just serve              # start HTTP + DHCP/TFTP + watcher (Ctrl-C stops all)

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
- Packages: openssh-server, curl, jq, net-tools, NetworkManager, unattended-upgrades, mosh, speedtest-cli
- Viam CLI + viam-agent (full/agent mode)
- Tailscale auto-join (if auth key provided)
